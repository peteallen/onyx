import AppKit
import ImageIO
import SwiftUI

struct NativeTranscriptView: NSViewControllerRepresentable {
    let items: [TimelineItem]
    var isAwaitingResponse = false
    var workingLabel = "Working"
    var revision: UInt64? = nil
    var changeHint: TranscriptCollectionUpdate.Hint? = nil
    var editableUserMessageID: String? = nil
    var retryableFailedResponseItemID: String? = nil
    var onEditUserMessage: (String) -> Void = { _ in }
    var onRetryFailedResponse: (String) -> Void = { _ in }

    func makeNSViewController(context: Context) -> TranscriptViewController {
        TranscriptViewController()
    }

    func updateNSViewController(_ controller: TranscriptViewController, context: Context) {
        // The native transcript owns attributed foregrounds instead of
        // inheriting SwiftUI's label color. Give it the hosting appearance
        // explicitly so newly recycled rows never resolve through the
        // process-wide default while the window is using the other scheme.
        controller.view.appearance = NSAppearance(
            named: context.environment.colorScheme == .dark ? .darkAqua : .aqua
        )
        controller.update(
            items: items,
            isAwaitingResponse: isAwaitingResponse,
            workingLabel: workingLabel,
            revision: revision,
            changeHint: changeHint,
            editableUserMessageID: editableUserMessageID,
            retryableFailedResponseItemID: retryableFailedResponseItemID,
            onEditUserMessage: onEditUserMessage,
            onRetryFailedResponse: onRetryFailedResponse
        )
    }
}

/// A UI-owned row for the gap between sending a message and receiving the
/// first provider event. Keeping it out of `TimelineItem` ensures it can never
/// leak into durable history or a provider's transcript.
struct TranscriptPendingResponse: Equatable {
    let isVisible: Bool
    let label: String

    static func resolve(
        items: [TimelineItem],
        isAwaitingResponse: Bool,
        label: String
    ) -> Self {
        guard isAwaitingResponse else { return Self(isVisible: false, label: label) }
        // A new task can still be showing the welcome assistant while its
        // provider-side thread is being created. With no sent user item in the
        // transcript yet, that old welcome copy must not suppress feedback for
        // the newly accepted send.
        let hasVisibleAssistant: Bool
        let isPreparingRetry = label == "Preparing retry…"
        if let lastUserIndex = items.lastIndex(where: { $0.kind == .userMessage }) {
            hasVisibleAssistant = items[items.index(after: lastUserIndex)...].contains {
                $0.kind == .assistantMessage
                    && (!isPreparingRetry || $0.status != .failed)
                    && !$0.body.isEmpty
            }
        } else {
            hasVisibleAssistant = false
        }
        return Self(isVisible: !hasVisibleAssistant, label: label)
    }
}

/// A presentation-only rollup for the high-frequency implementation events
/// that otherwise make a turn read like a long stack of log cards.  The
/// durable timeline remains unchanged: every child keeps its provider ID and
/// can be shown again by opening the rollup.
struct TranscriptActivityGroup: Identifiable, Equatable {
    let id: String
    let range: Range<Int>
    let itemIDs: [String]
    let title: String
    let summary: String

    var count: Int { range.count }

    /// The structural part of a group.  Presentation text can change while
    /// streaming without forcing a collection reload; a changed range or
    /// child identity does require one because the visible row topology moved.
    var structureKey: String {
        "\(id)|\(itemIDs.joined(separator: ","))"
    }
}

enum TranscriptActivityGrouping {
    /// Keep rollups deliberately small.  A user can always expand one group
    /// to inspect every child, while a pathological provider payload cannot
    /// turn one compact row into an unbounded summary operation.
    static let maximumItemsPerGroup = 8
    static let maximumBodyBytesPerGroup = 24_000

    struct AppendInstrumentation: Equatable {
        fileprivate(set) var inspectedItemCount = 0
    }

    struct AppendResult: Equatable {
        let itemStart: Int
        let groupStart: Int
    }

    fileprivate struct TailMutation {
        let result: AppendResult
        let replacementGroups: [TranscriptActivityGroup]
    }

    static func groups(for items: [TimelineItem]) -> [TranscriptActivityGroup] {
        var instrumentation = AppendInstrumentation()
        return groups(
            for: items,
            startingAt: 0,
            instrumentation: &instrumentation
        )
    }

    /// Extends a previously computed projection by rescanning only the old
    /// mutable tail plus the appended items. Earlier groups are immutable
    /// because an append cannot cross a non-groupable row or a completed group
    /// boundary.
    static func append(
        to groups: inout [TranscriptActivityGroup],
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        appendedRange: Range<Int>,
        instrumentation: inout AppendInstrumentation
    ) -> AppendResult? {
        guard let mutation = appendMutation(
            for: groups,
            oldItems: oldItems,
            newItems: newItems,
            appendedRange: appendedRange,
            instrumentation: &instrumentation
        ) else { return nil }
        groups.replaceSubrange(
            mutation.result.groupStart..<groups.endIndex,
            with: mutation.replacementGroups
        )
        return mutation.result
    }

    /// Plans a bounded suffix replacement without requiring the caller's
    /// group storage to be one contiguous array. This keeps prepended group
    /// pages offset-backed while preserving the array API used by model tests.
    fileprivate static func appendMutation<Groups: RandomAccessCollection>(
        for groups: Groups,
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        appendedRange: Range<Int>,
        instrumentation: inout AppendInstrumentation
    ) -> TailMutation? where Groups.Index == Int, Groups.Element == TranscriptActivityGroup {
        guard appendedRange.lowerBound == oldItems.count,
              appendedRange.upperBound == newItems.count,
              !appendedRange.isEmpty else { return nil }

        var itemStart = oldItems.count
        let firstAppended = newItems[appendedRange.lowerBound]
        if isGroupable(firstAppended) {
            if let tailGroup = groups.last,
               tailGroup.range.upperBound == oldItems.count {
                itemStart = tailGroup.range.lowerBound
            } else if let oldTail = oldItems.last, isGroupable(oldTail) {
                // A lone groupable tail row was deliberately left ungrouped.
                // It may now form a rollup with the first appended activity.
                itemStart = oldItems.count - 1
            }
        }

        var groupStart = groups.endIndex
        while groupStart > groups.startIndex {
            let candidateIndex = groups.index(before: groupStart)
            guard groups[candidateIndex].range.upperBound > itemStart else { break }
            groupStart = candidateIndex
        }
        let replacements = self.groups(
            for: newItems,
            startingAt: itemStart,
            instrumentation: &instrumentation
        )
        return TailMutation(
            result: AppendResult(itemStart: itemStart, groupStart: groupStart),
            replacementGroups: replacements
        )
    }

    static func append(
        to groups: inout [TranscriptActivityGroup],
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        appendedRange: Range<Int>
    ) -> AppendResult? {
        var instrumentation = AppendInstrumentation()
        return append(
            to: &groups,
            oldItems: oldItems,
            newItems: newItems,
            appendedRange: appendedRange,
            instrumentation: &instrumentation
        )
    }

    /// Reprojects a same-length mutation at the end of the transcript without
    /// revisiting stable history. Completion is the common case: a live tool
    /// row becomes eligible to join the immediately preceding compact group.
    /// At most that mutable group, one lone activity, and the changed tail need
    /// to be reconsidered.
    static func replaceChangedTail(
        in groups: inout [TranscriptActivityGroup],
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        changedIndex: Int,
        instrumentation: inout AppendInstrumentation
    ) -> AppendResult? {
        guard let mutation = replaceChangedTailMutation(
            in: groups,
            oldItems: oldItems,
            newItems: newItems,
            changedIndex: changedIndex,
            instrumentation: &instrumentation
        ) else { return nil }
        groups.replaceSubrange(
            mutation.result.groupStart..<groups.endIndex,
            with: mutation.replacementGroups
        )
        return mutation.result
    }

    fileprivate static func replaceChangedTailMutation<Groups: RandomAccessCollection>(
        in groups: Groups,
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        changedIndex: Int,
        instrumentation: inout AppendInstrumentation
    ) -> TailMutation? where Groups.Index == Int, Groups.Element == TranscriptActivityGroup {
        guard oldItems.count == newItems.count,
              changedIndex == oldItems.count - 1,
              oldItems.indices.contains(changedIndex),
              oldItems[changedIndex].id == newItems[changedIndex].id else { return nil }

        var itemStart = changedIndex
        if let tailGroup = groups.last,
           tailGroup.range.upperBound >= changedIndex {
            // This is either the group containing the old tail or the group
            // directly before a formerly live/lone tail.
            itemStart = tailGroup.range.lowerBound
        } else if changedIndex > 0,
                  isGroupable(oldItems[changedIndex - 1])
                    || isGroupable(newItems[changedIndex - 1]) {
            itemStart = changedIndex - 1
        }

        var groupStart = groups.endIndex
        while groupStart > groups.startIndex {
            let candidateIndex = groups.index(before: groupStart)
            guard groups[candidateIndex].range.upperBound > itemStart else { break }
            groupStart = candidateIndex
        }
        let replacements = self.groups(
            for: newItems,
            startingAt: itemStart,
            instrumentation: &instrumentation
        )
        return TailMutation(
            result: AppendResult(itemStart: itemStart, groupStart: groupStart),
            replacementGroups: replacements
        )
    }

    static func replaceChangedTail(
        in groups: inout [TranscriptActivityGroup],
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        changedIndex: Int
    ) -> AppendResult? {
        var instrumentation = AppendInstrumentation()
        return replaceChangedTail(
            in: &groups,
            oldItems: oldItems,
            newItems: newItems,
            changedIndex: changedIndex,
            instrumentation: &instrumentation
        )
    }

    private static func groups(
        for items: [TimelineItem],
        startingAt initialStart: Int,
        instrumentation: inout AppendInstrumentation
    ) -> [TranscriptActivityGroup] {
        guard items.indices.contains(initialStart) else { return [] }

        var groups: [TranscriptActivityGroup] = []
        var start = initialStart
        while start < items.count {
            instrumentation.inspectedItemCount += 1
            guard isGroupable(items[start]) else {
                start += 1
                continue
            }

            var end = start
            var bodyBytes = 0
            while end < items.count,
                  end - start < maximumItemsPerGroup,
                  isGroupable(items[end]) {
                if end != start { instrumentation.inspectedItemCount += 1 }
                let availableBytes = max(0, maximumBodyBytesPerGroup - bodyBytes)
                // Counting a complete multi-megabyte payload would defeat the
                // projection's bound. One byte beyond the remaining allowance
                // is enough to make the grouping decision.
                let nextBytes = items[end].body.utf8.prefix(availableBytes + 1).count
                guard bodyBytes == 0
                        || (bodyBytes <= maximumBodyBytesPerGroup && nextBytes <= availableBytes)
                else { break }
                bodyBytes = min(maximumBodyBytesPerGroup + 1, bodyBytes + nextBytes)
                end += 1
            }

            guard end - start >= 2 else {
                start += 1
                continue
            }

            let groupedItems = items[start..<end]
            let firstID = groupedItems.first!.id
            groups.append(
                TranscriptActivityGroup(
                    id: "activity-group:\(firstID)",
                    range: start..<end,
                    itemIDs: groupedItems.map(\.id),
                    title: title(for: groupedItems),
                    summary: "\(groupedItems.count) activities"
                )
            )
            start = end
        }
        return groups
    }

    /// A text-only update to an assistant message, plan, approval, error, or
    /// collaboration row cannot alter the activity topology. Keep those live
    /// update paths bounded instead of rebuilding every rollup in history.
    static func requiresProjectionRebuild(
        for update: TranscriptCollectionUpdate,
        from oldItems: [TimelineItem],
        to newItems: [TimelineItem]
    ) -> Bool {
        switch update {
        case .unchanged:
            false
        case let .tailChange(index):
            groupingCanChange(at: index, from: oldItems, to: newItems)
        case let .rowChanges(indices):
            indices.contains { groupingCanChange(at: $0, from: oldItems, to: newItems) }
        case .append, .prepend, .reloadAll:
            true
        }
    }

    private static func groupingCanChange(
        at index: Int,
        from oldItems: [TimelineItem],
        to newItems: [TimelineItem]
    ) -> Bool {
        guard oldItems.indices.contains(index), newItems.indices.contains(index) else { return true }
        return isGroupable(oldItems[index]) || isGroupable(newItems[index])
    }

    static func isGroupable(_ item: TimelineItem) -> Bool {
        // Live and exceptional rows must remain independently visible. Agent
        // activity is also excluded so its existing click-through surface is
        // never hidden behind a generic tool rollup.
        item.kind.isRoutineActivity
            && item.status == .completed
            && item.collaboration == nil
    }

    private static func title(for items: ArraySlice<TimelineItem>) -> String {
        var sawReasoning = false
        var sawCommand = false
        var sawFileChange = false
        var sawTool = false
        for item in items {
            switch item.kind {
            case .reasoning: sawReasoning = true
            case .command: sawCommand = true
            case .fileChange: sawFileChange = true
            case .tool: sawTool = true
            case .userMessage, .assistantMessage, .plan, .approval, .system, .error: break
            }
        }

        var labels: [String] = []
        // Keep the summary semantic but conservative. Commands can read files,
        // run tests, launch builds, or combine all three, so the UI should not
        // overclaim their effect by parsing shell syntax.
        if sawCommand { labels.append("Ran commands") }
        if sawFileChange { labels.append("changed files") }
        if sawTool { labels.append("used tools") }
        if sawReasoning { labels.append("reasoned") }
        return labels.isEmpty ? "Activity" : labels.joined(separator: ", ")
    }
}

enum TranscriptCollectionUpdate: Equatable {
    case unchanged
    case tailChange(Int)
    case rowChanges(IndexSet)
    case append(Range<Int>)
    case prepend(Range<Int>)
    case reloadAll

    struct PlanningInstrumentation: Equatable {
        fileprivate(set) var inspectedItemCount = 0
        fileprivate(set) var hintedUpdateCount = 0
    }

    enum Hint: Equatable, Sendable {
        /// One or more consecutive `append(_:)` mutations extending the same
        /// immutable prefix. Each revision in this lineage adds exactly one
        /// item, which lets a controller that missed an intermediate SwiftUI
        /// publication still validate its old count without rescanning every
        /// historical row.
        case itemsAppended(
            startIndex: Int,
            fromRevision: UInt64,
            toRevision: UInt64
        )
        /// One bounded page was inserted before an immutable visible suffix.
        /// Unlike an arbitrary middle insertion, this can be applied without
        /// recycling mounted transcript rows and while anchoring the viewport.
        case itemsPrepended(
            count: Int,
            fromRevision: UInt64,
            toRevision: UInt64
        )
        /// This hint must be emitted atomically with the mutation that creates
        /// `toRevision`: collection shape and item identities remain unchanged,
        /// and every item outside `indices` is byte-for-byte unchanged.
        case rowsChanged(indices: IndexSet, fromRevision: UInt64, toRevision: UInt64)
    }

    /// Computes the smallest collection-view update that is safe for the new
    /// snapshot. Identity changes, deletion, and non-tail structural edits use
    /// a full reload so an incorrect incremental update can never desynchronise
    /// AppKit's item count from the data source.
    static func plan(
        from oldItems: [TimelineItem],
        to newItems: [TimelineItem],
        oldRevision: UInt64? = nil,
        newRevision: UInt64? = nil,
        hint: Hint? = nil,
        instrumentation: inout PlanningInstrumentation
    ) -> Self {
        // The model publishes items and revision atomically. SwiftUI may call
        // update again because unrelated task state changed; an identical
        // non-nil revision proves the transcript snapshot itself is unchanged
        // without rescanning a large history or attempting to reuse its last
        // one-shot hint.
        if let oldRevision, oldRevision == newRevision {
            return .unchanged
        }
        guard !oldItems.isEmpty else {
            return newItems.isEmpty ? .unchanged : .reloadAll
        }

        if case let .itemsAppended(startIndex, fromRevision, toRevision) = hint,
           let oldRevision,
           let newRevision,
           newRevision == toRevision,
           oldRevision >= fromRevision,
           oldRevision < toRevision,
           let oldOffset = Int(exactly: oldRevision - fromRevision),
           let newOffset = Int(exactly: toRevision - fromRevision),
           startIndex >= 0,
           oldItems.count == startIndex + oldOffset,
           newItems.count == startIndex + newOffset {
            instrumentation.hintedUpdateCount += 1
            return .append(oldItems.count..<newItems.count)
        }

        if case let .itemsPrepended(count, fromRevision, toRevision) = hint,
           oldRevision == fromRevision,
           newRevision == toRevision,
           count > 0,
           newItems.count == oldItems.count + count {
            instrumentation.hintedUpdateCount += 1
            return .prepend(0..<count)
        }

        if case let .rowsChanged(indices, fromRevision, toRevision) = hint,
           oldRevision == fromRevision,
           newRevision == toRevision,
           oldItems.count == newItems.count,
           !indices.isEmpty,
           indices.allSatisfy({ oldItems.indices.contains($0) }) {
            for index in indices {
                instrumentation.inspectedItemCount += 1
                guard oldItems[index].id == newItems[index].id,
                      oldItems[index] != newItems[index] else {
                    return planWithoutHint(
                        from: oldItems,
                        to: newItems,
                        instrumentation: &instrumentation
                    )
                }
            }
            instrumentation.hintedUpdateCount += 1
            if indices.count == 1, indices.contains(newItems.count - 1) {
                return .tailChange(newItems.count - 1)
            }
            return .rowChanges(indices)
        }

        return planWithoutHint(
            from: oldItems,
            to: newItems,
            instrumentation: &instrumentation
        )
    }

    static func plan(from oldItems: [TimelineItem], to newItems: [TimelineItem]) -> Self {
        var instrumentation = PlanningInstrumentation()
        return plan(
            from: oldItems,
            to: newItems,
            instrumentation: &instrumentation
        )
    }

    private static func planWithoutHint(
        from oldItems: [TimelineItem],
        to newItems: [TimelineItem],
        instrumentation: inout PlanningInstrumentation
    ) -> Self {
        guard !oldItems.isEmpty else {
            return newItems.isEmpty ? .unchanged : .reloadAll
        }

        if newItems.count > oldItems.count {
            for index in oldItems.indices {
                instrumentation.inspectedItemCount += 1
                guard oldItems[index].id == newItems[index].id,
                      oldItems[index] == newItems[index] else {
                    return .reloadAll
                }
            }
            return .append(oldItems.count..<newItems.count)
        }

        guard oldItems.count == newItems.count else { return .reloadAll }

        var changed = IndexSet()
        for index in oldItems.indices {
            instrumentation.inspectedItemCount += 1
            guard oldItems[index].id == newItems[index].id else { return .reloadAll }
            if oldItems[index] != newItems[index] {
                changed.insert(index)
            }
        }

        guard !changed.isEmpty else { return .unchanged }
        if changed.count == 1, changed.contains(newItems.count - 1) {
            return .tailChange(newItems.count - 1)
        }
        return .rowChanges(changed)
    }
}

struct TranscriptLayoutInstrumentation: Equatable {
    fileprivate(set) var measurementCount = 0
    fileprivate(set) var cacheHitCount = 0
    fileprivate(set) var invalidatedRowCount = 0
    fileprivate(set) var globalInvalidationCount = 0
}

/// Owns the row-height cache independently from AppKit so update behaviour can
/// be tested deterministically. A cached height is valid only for the same
/// stable item identity, layout-affecting content revision, and readable width.
struct TranscriptLayoutState {
    static let maximumVisibleAttachments = 4
    static let maximumVisibleLinks = 6

    private struct LayoutRevision: Equatable {
        let kind: String
        let status: TimelineItemStatus
        let title: String?
        let body: String
        let detail: String?
        /// `nil` is the legacy/bounded measurement mode used by the layout
        /// cache tests.  A concrete value is used by the live transcript so
        /// expansion is part of the cache key and a toggle can never reuse a
        /// collapsed row's height for its expanded counterpart.
        let isExpanded: Bool?
        let visibleAttachmentCount: Int
        let visibleAttachmentIDs: [String]
        let links: [TimelineResourceLink]

        init(item: TimelineItem, isExpanded: Bool? = nil) {
            kind = item.kind.rawValue
            status = item.status
            title = item.title
            body = item.body
            detail = item.detail
            self.isExpanded = isExpanded
            let showAllMedia = isExpanded == true
            visibleAttachmentCount = min(
                showAllMedia ? item.attachments.count : TranscriptLayoutState.maximumVisibleAttachments,
                item.attachments.count
            )
            visibleAttachmentIDs = Array(
                (showAllMedia ? item.attachments : Array(item.attachments.prefix(TranscriptLayoutState.maximumVisibleAttachments)))
                    .map(\.id)
            )
            links = showAllMedia
                ? item.links
                : Array(item.links.prefix(TranscriptLayoutState.maximumVisibleLinks))
        }
    }

    private struct CachedHeight {
        let revision: LayoutRevision
        let width: CGFloat
        let height: CGFloat
    }

    private var cachedHeightsByItemID: [String: CachedHeight] = [:]
    private var observedReadableWidth: CGFloat?
    private(set) var instrumentation = TranscriptLayoutInstrumentation()

    mutating func prepare(
        for update: TranscriptCollectionUpdate,
        newItems: [TimelineItem]
    ) {
        switch update {
        case .unchanged, .append, .prepend:
            break
        case let .tailChange(index):
            invalidateRows(IndexSet(integer: index), in: newItems)
        case let .rowChanges(indices):
            invalidateRows(indices, in: newItems)
        case .reloadAll:
            reconcileCache(with: newItems)
        }
    }

    mutating func height(
        for item: TimelineItem,
        width: CGFloat,
        measure: () -> CGFloat
    ) -> CGFloat {
        height(for: item, width: width, isExpanded: nil, measure: measure)
    }

    mutating func height(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        measure: () -> CGFloat
    ) -> CGFloat {
        height(for: item, width: width, isExpanded: Optional(isExpanded), measure: measure)
    }

    private mutating func height(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool?,
        measure: () -> CGFloat
    ) -> CGFloat {
        let revision = LayoutRevision(item: item, isExpanded: isExpanded)
        if let cached = cachedHeightsByItemID[item.id],
           cached.revision == revision,
           cached.width == width {
            instrumentation.cacheHitCount += 1
            return cached.height
        }

        let height = measure()
        cachedHeightsByItemID[item.id] = CachedHeight(
            revision: revision,
            width: width,
            height: height
        )
        instrumentation.measurementCount += 1
        return height
    }

    /// Expansion is independent UI state, so changing it must invalidate only
    /// the affected row.  Keeping this operation on the cache owner prevents
    /// a recycled collection item from accidentally inheriting another row's
    /// height.
    mutating func invalidate(itemID: String) {
        guard cachedHeightsByItemID.removeValue(forKey: itemID) != nil else { return }
        instrumentation.invalidatedRowCount += 1
    }

    /// Returns true only when existing layout attributes must be invalidated.
    /// Establishing the initial width is not a change.
    mutating func readableWidthDidChange(to width: CGFloat) -> Bool {
        guard let previousWidth = observedReadableWidth else {
            observedReadableWidth = width
            return false
        }
        guard previousWidth != width else { return false }

        observedReadableWidth = width
        cachedHeightsByItemID.removeAll(keepingCapacity: true)
        instrumentation.globalInvalidationCount += 1
        return true
    }

    private mutating func invalidateRows(_ indices: IndexSet, in items: [TimelineItem]) {
        for index in indices where items.indices.contains(index) {
            cachedHeightsByItemID.removeValue(forKey: items[index].id)
            instrumentation.invalidatedRowCount += 1
        }
    }

    private mutating func reconcileCache(with items: [TimelineItem]) {
        var currentItems: [String: TimelineItem] = [:]
        currentItems.reserveCapacity(items.count)
        for item in items {
            if currentItems.updateValue(item, forKey: item.id) != nil {
                // Timeline identities are expected to be unique. If a provider
                // violates that contract, sharing one cached height is unsafe.
                cachedHeightsByItemID.removeAll(keepingCapacity: true)
                return
            }
        }

        cachedHeightsByItemID = cachedHeightsByItemID.filter { itemID, cached in
            guard let item = currentItems[itemID] else { return false }
            // Keep the cache's rendering mode (legacy bounded vs explicit
            // collapsed/expanded) while validating the new content. This
            // avoids a full re-measure merely because a stream caused a safe
            // collection reload.
            return LayoutRevision(item: item, isExpanded: cached.revision.isExpanded) == cached.revision
        }
    }
}

/// Keeps the flow-layout delegate's row width and section insets on one
/// sizing contract. AppKit requires the row to be *strictly* narrower than
/// the collection width after insets; an exact fit enters undefined layout
/// behavior and can crash while a hosting view is being resized.
struct TranscriptFlowMetrics: Equatable {
    /// Transcript rows use the whole pane between the same modest side gutters
    /// as the composer. Very narrow transition frames scale both gutters down
    /// before allowing a row to overflow.
    static let preferredLeadingInset = OnyxWorkspaceMetrics.preferredConversationSideInset
    static let preferredTrailingInset = OnyxWorkspaceMetrics.preferredConversationSideInset
    static let layoutSafetyWidth: CGFloat = 1

    let itemWidth: CGFloat
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    init(collectionWidth rawCollectionWidth: CGFloat) {
        let collectionWidth = rawCollectionWidth.isFinite
            ? max(0, rawCollectionWidth)
            : 0
        guard collectionWidth > Self.layoutSafetyWidth else {
            itemWidth = 0
            leadingInset = 0
            trailingInset = 0
            return
        }

        let preferredSideInset = OnyxWorkspaceMetrics.conversationSideInset(
            availableWidth: collectionWidth
        )
        let preferredInsetWidth = preferredSideInset * 2
        itemWidth = max(
            1,
            collectionWidth
                - preferredInsetWidth
                - Self.layoutSafetyWidth
        )
        let availableInsetWidth = max(
            0,
            collectionWidth - itemWidth - Self.layoutSafetyWidth
        )
        if availableInsetWidth >= preferredInsetWidth {
            leadingInset = preferredSideInset
            trailingInset = availableInsetWidth - leadingInset
        } else {
            leadingInset = availableInsetWidth / 2
            trailingInset = availableInsetWidth - leadingInset
        }
    }
}

/// Computes the flexible top space needed to keep a short transcript in the
/// same lower-third gravity as the composer.  A collection view normally
/// clamps a short document to y=0, which leaves a one- or two-message task
/// stranded at the top of a very large black canvas.  The offset belongs to
/// the layout (rather than a synthetic data-source row) so row identities,
/// pagination, and viewport anchoring stay unchanged.
enum TranscriptVerticalAlignment {
    static func extraTopOffset(
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
        hasContent: Bool = true
    ) -> CGFloat {
        guard hasContent,
              viewportHeight.isFinite,
              contentHeight.isFinite,
              viewportHeight > 0,
              contentHeight > 0 else { return 0 }
        return max(0, viewportHeight - contentHeight)
    }
}

private final class TranscriptCollectionFlowLayout: NSCollectionViewFlowLayout {
    private(set) var extraTopOffset: CGFloat = 0

    override func prepare() {
        super.prepare()

        // `super.collectionViewContentSize` is the intrinsic document height,
        // including the ordinary 18/24 pt section insets.  Add flexible space
        // only while that intrinsic document is shorter than the visible clip
        // view; long transcripts retain their existing scroll geometry.
        let viewportHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        let intrinsicHeight = super.collectionViewContentSize.height
        extraTopOffset = TranscriptVerticalAlignment.extraTopOffset(
            viewportHeight: viewportHeight,
            contentHeight: intrinsicHeight,
            hasContent: (collectionView?.numberOfItems(inSection: 0) ?? 0) > 0
        )
    }

    override var collectionViewContentSize: NSSize {
        var size = super.collectionViewContentSize
        size.height += extraTopOffset
        return size
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard extraTopOffset > 0 else {
            return super.layoutAttributesForElements(in: rect)
        }
        let translatedRect = rect.offsetBy(dx: 0, dy: -extraTopOffset)
        return super.layoutAttributesForElements(in: translatedRect).map { attributes in
            let copy = attributes.copy() as! NSCollectionViewLayoutAttributes
            copy.frame.origin.y += extraTopOffset
            return copy
        }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForItem(at: indexPath) else {
            return nil
        }
        guard extraTopOffset > 0 else { return attributes }
        let copy = attributes.copy() as! NSCollectionViewLayoutAttributes
        copy.frame.origin.y += extraTopOffset
        return copy
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        // The lower-third offset depends on the visible clip height as well
        // as the transcript width.  AppKit's flow layout generally only
        // invalidates for width changes; explicitly treating a height change
        // as a metric change keeps the offset correct during live window
        // resizes (and does not fire for ordinary vertical scrolling).
        return collectionView.bounds.width != newBounds.width
            || collectionView.bounds.height != newBounds.height
            || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let flowContext = context as? NSCollectionViewFlowLayoutInvalidationContext {
            flowContext.invalidateFlowLayoutDelegateMetrics = true
            flowContext.invalidateFlowLayoutAttributes = true
        }
        return context
    }
}

struct TranscriptPrependInstrumentation: Equatable {
    fileprivate(set) var insertedDisplayRowCount = 0
    fileprivate(set) var projectedPrefixItemCount = 0
    fileprivate(set) var projectedPrefixGroupCount = 0
    fileprivate(set) var fullReloadCount = 0
    fileprivate(set) var projectionFullReloadCount = 0
    fileprivate(set) var displayIndexRebuildCount = 0
    fileprivate(set) var anchorFallbackScanCount = 0
    fileprivate(set) var deferredReloadLookupCount = 0
    fileprivate(set) var nearTailLookupCount = 0
    fileprivate(set) var nearTailInspectedRowCount = 0
    fileprivate(set) var nearTailLookupBudgetExceededCount = 0
    fileprivate(set) var tailGroupingInspectedItemCount = 0
    fileprivate(set) var suffixBatchUpdateCount = 0
}

final class TranscriptViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    /// A mutable rollup contains at most eight children. An expanded rollup,
    /// its summary, and the adjacent live/lone row therefore fit within this
    /// hard fallback budget.
    static let maximumNearTailLookupRows = TranscriptActivityGrouping.maximumItemsPerGroup + 4
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptItem")
    private static let pendingItemIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptPendingItem")
    private static let activityGroupIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptActivityGroupItem")

    private enum DisplayRow {
        case item(index: Int)
        case activityGroup(TranscriptActivityGroup)

        var id: String {
            switch self {
            case let .item(index): "item:\(index)"
            case let .activityGroup(group): group.id
            }
        }
    }

    /// Stores prepended pages without copying or rewriting the mounted suffix.
    /// Each page remembers the cumulative item offset at creation; rows are
    /// shifted lazily when AppKit asks for one visible element.
    private struct PrependOffsetStorage<Element>: RandomAccessCollection {
        typealias Index = Int

        private struct Stored {
            let element: Element
            let prependOffset: Int
        }

        private var prependedPages: [[Stored]] = []
        private var prependedPageEnds: [Int] = []
        private var tail: [Stored] = []
        private var currentPrependOffset = 0
        private let shifted: (Element, Int) -> Element
        private(set) var fullMaterializationCount = 0

        init(shifted: @escaping (Element, Int) -> Element) {
            self.shifted = shifted
        }

        var startIndex: Int { 0 }
        var endIndex: Int { (prependedPageEnds.last ?? 0) + tail.count }

        subscript(position: Int) -> Element {
            precondition(indices.contains(position))
            let prependedCount = prependedPageEnds.last ?? 0
            let stored: Stored
            if position < prependedCount {
                // Pages and their elements are retained in insertion order;
                // reading that storage backwards yields chronological display
                // order after successively older pages are added.
                let reverseOffset = prependedCount - 1 - position
                var lower = 0
                var upper = prependedPageEnds.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if prependedPageEnds[middle] > reverseOffset {
                        upper = middle
                    } else {
                        lower = middle + 1
                    }
                }
                let pageIndex = lower
                let priorEnd = pageIndex == 0 ? 0 : prependedPageEnds[pageIndex - 1]
                stored = prependedPages[pageIndex][reverseOffset - priorEnd]
            } else {
                stored = tail[position - prependedCount]
            }
            return shifted(stored.element, currentPrependOffset - stored.prependOffset)
        }

        mutating func replaceAll(with elements: [Element]) {
            prependedPages.removeAll(keepingCapacity: true)
            prependedPageEnds.removeAll(keepingCapacity: true)
            tail = elements.map { Stored(element: $0, prependOffset: currentPrependOffset) }
        }

        mutating func prepend(_ elements: [Element], itemOffset: Int) {
            guard itemOffset != 0 else { return }
            currentPrependOffset += itemOffset
            guard !elements.isEmpty else { return }
            prependedPages.append(elements.reversed().map {
                Stored(element: $0, prependOffset: currentPrependOffset)
            })
            prependedPageEnds.append((prependedPageEnds.last ?? 0) + elements.count)
        }

        mutating func removeSubrange(_ bounds: Range<Int>) {
            guard !bounds.isEmpty else { return }
            let prependedCount = prependedPageEnds.last ?? 0
            if bounds.lowerBound >= prependedCount {
                tail.removeSubrange(
                    (bounds.lowerBound - prependedCount)..<(bounds.upperBound - prependedCount)
                )
                return
            }

            fullMaterializationCount += 1
            var materialized = Array(self)
            materialized.removeSubrange(bounds)
            replaceAll(with: materialized)
        }

        mutating func append(contentsOf elements: [Element]) {
            tail.append(contentsOf: elements.map {
                Stored(element: $0, prependOffset: currentPrependOffset)
            })
        }
    }

    private struct AppendProjectionChange {
        let displayStart: Int
        let oldDisplayCount: Int
        let oldTailIDs: [String]
        let newTailIDs: [String]
        let requiresReload: Bool
    }

    private struct PrependProjectionChange {
        let insertedDisplayCount: Int
        let requiresReload: Bool
    }

    private struct ViewportAnchor {
        let rowID: String
        let displayIndex: Int
        let offsetFromViewportTop: CGFloat
    }

    /// The pending-response row is presentation-only, but it still occupies
    /// a real collection-view index. Keep its old and new topology alongside
    /// every transcript projection mutation so AppKit sees one coherent
    /// transaction when a first token arrives at the same time that the row
    /// disappears.
    private struct PendingResponseChange {
        let old: TranscriptPendingResponse
        let new: TranscriptPendingResponse
        let oldDisplayCount: Int

        var visibilityChanged: Bool { old.isVisible != new.isVisible }
        var labelChanged: Bool {
            old.isVisible && new.isVisible && old.label != new.label
        }
    }

    /// AppKit can ask for a deleted collection item while laying out the same
    /// batch that removes it. Keep the old presentation row addressable until
    /// that transaction and its immediate post-layout pass have retired it;
    /// it never contributes to the new data-source count.
    private struct RetiringPendingResponse {
        let token: UInt64
        let displayIndex: Int
        let response: TranscriptPendingResponse
    }

    private struct TailProjectionChange {
        let displayStart: Int
        let oldDisplayCount: Int
        let oldTailIDs: [String]
        let newTailIDs: [String]
        let requiresReload: Bool
    }

    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let layout = TranscriptCollectionFlowLayout()
    private var items: [TimelineItem] = []
    private var itemsRevision: UInt64?
    private var layoutState = TranscriptLayoutState()
    private var pendingResponse = TranscriptPendingResponse(isVisible: false, label: "Working")
    private var retiringPendingResponses: [RetiringPendingResponse] = []
    private var nextPendingResponseRetirementToken: UInt64 = 0
    /// Collection rows are presentation-only. A collapsed activity group
    /// replaces its contiguous children with one summary row; expanding it
    /// puts the original children back at their stable positions.
    private var displayRows = PrependOffsetStorage<DisplayRow> { row, offset in
        switch row {
        case let .item(index): .item(index: index + offset)
        case let .activityGroup(group): .activityGroup(TranscriptActivityGroup(
            id: group.id,
            range: (group.range.lowerBound + offset)..<(group.range.upperBound + offset),
            itemIDs: group.itemIDs,
            title: group.title,
            summary: group.summary
        ))
        }
    }
    private var activityGroups = PrependOffsetStorage<TranscriptActivityGroup> { group, offset in
        TranscriptActivityGroup(
            id: group.id,
            range: (group.range.lowerBound + offset)..<(group.range.upperBound + offset),
            itemIDs: group.itemIDs,
            title: group.title,
            summary: group.summary
        )
    }
    private var displayIndexByItemIndex: [Int: Int] = [:]
    private var groupDisplayIndexByItemIndex: [Int: Int] = [:]
    /// A prepend shifts every historical row's item index. Defer rebuilding
    /// these auxiliary lookup maps until an operation that needs them, so
    /// repeated older-page loads do not rescan the whole transcript.
    private var displayIndexIsDirty = false
    /// After a prepend, the existing lookup maps still describe the mounted
    /// suffix. Keep its item/display offsets separately so a live tail update
    /// can resolve its row without rebuilding maps for the whole transcript.
    private var deferredItemIndexOffset = 0
    private var deferredDisplayIndexOffset = 0
    private var expandedActivityGroupIDs = Set<String>()
    /// Expansion follows provider-stable timeline IDs, never collection
    /// indexes. Streaming and insertion can recycle cells while preserving a
    /// row's identity.
    private var expandedItemIDs = Set<String>()
    private var hasScheduledFollowScroll = false
    private var observedViewportHeight: CGFloat?
    private var editableUserMessageID: String?
    private var retryableFailedResponseItemID: String?
    private var onEditUserMessage: (String) -> Void = { _ in }
    private var onRetryFailedResponse: (String) -> Void = { _ in }
    private(set) var prependInstrumentation = TranscriptPrependInstrumentation()
    var projectionStorageMaterializationCount: Int {
        displayRows.fullMaterializationCount + activityGroups.fullMaterializationCount
    }
    var layoutExtraTopOffsetForTesting: CGFloat { layout.extraTopOffset }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        // Compact activity rows should read as one execution stream rather
        // than a stack of unrelated cards. A small shared gap visually groups
        // adjacent routine events without merging their identities or hiding
        // any detail from the disclosure control.
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        // The delegate supplies the centered horizontal inset from the live
        // collection width. Keep the layout's fallback inset zero so AppKit
        // never combines a stale 24pt margin with a transiently tiny hosting
        // view during a resize.
        layout.sectionInset = NSEdgeInsets(top: 18, left: 0, bottom: 24, right: 0)
        layout.scrollDirection = .vertical

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            TranscriptCollectionItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )
        collectionView.register(
            TranscriptPendingCollectionItem.self,
            forItemWithIdentifier: Self.pendingItemIdentifier
        )
        collectionView.register(
            TranscriptActivityGroupCollectionItem.self,
            forItemWithIdentifier: Self.activityGroupIdentifier
        )

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        _ = layoutState.readableWidthDidChange(to: readableWidth)
    }

    func update(
        items newItems: [TimelineItem],
        isAwaitingResponse: Bool = false,
        workingLabel: String = "Working",
        revision newRevision: UInt64? = nil,
        changeHint: TranscriptCollectionUpdate.Hint? = nil,
        editableUserMessageID newEditableUserMessageID: String? = nil,
        retryableFailedResponseItemID newRetryableFailedResponseItemID: String? = nil,
        onEditUserMessage newOnEditUserMessage: @escaping (String) -> Void = { _ in },
        onRetryFailedResponse newOnRetryFailedResponse: @escaping (String) -> Void = { _ in }
    ) {
        let previousRetryableFailedResponseItemID = retryableFailedResponseItemID
        editableUserMessageID = newEditableUserMessageID
        retryableFailedResponseItemID = newRetryableFailedResponseItemID
        onEditUserMessage = newOnEditUserMessage
        onRetryFailedResponse = newOnRetryFailedResponse
        let shouldFollow = isNearBottom
        let oldItems = items
        var planningInstrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        let update = TranscriptCollectionUpdate.plan(
            from: oldItems,
            to: newItems,
            oldRevision: itemsRevision,
            newRevision: newRevision,
            hint: changeHint,
            instrumentation: &planningInstrumentation
        )
        let newPendingResponse = TranscriptPendingResponse.resolve(
            items: newItems,
            isAwaitingResponse: isAwaitingResponse,
            label: workingLabel
        )
        // Retryability is presentation state rather than transcript content,
        // so the snapshot revision can remain unchanged while a mounted
        // assistant row gains or loses its Retry action. Invalidate only the
        // affected rows and reload them through the same collection update
        // transaction; updating the recycled cell alone leaves the flow
        // layout's old height cached and can clip the action or overlap text.
        var retryActionReloadIndices = IndexSet()
        if previousRetryableFailedResponseItemID != newRetryableFailedResponseItemID {
            let affectedIDs = Set([
                previousRetryableFailedResponseItemID,
                newRetryableFailedResponseItemID,
            ].compactMap { $0 })
            for itemID in affectedIDs {
                guard let index = newItems.firstIndex(where: { $0.id == itemID }) else {
                    continue
                }
                retryActionReloadIndices.insert(index)
                layoutState.invalidate(itemID: itemID)
            }
        }
        // Keep the old presentation row mounted while applying transcript
        // mutations.  The pending row is always the final collection item;
        // deferring this state change lets AppKit reconcile transcript inserts
        // and the pending-row insert/delete against the correct old item
        // count, without a full reload of a potentially long history.
        let oldPendingResponse = pendingResponse
        let pendingResponseChange = PendingResponseChange(
            old: oldPendingResponse,
            new: newPendingResponse,
            oldDisplayCount: displayRows.count
        )
        if update == .reloadAll {
            let validExpandableIDs = Set(
                newItems.lazy
                    .filter { $0.kind.isCollapsibleActivity }
                    .map(\.id)
            )
            expandedItemIDs.formIntersection(validExpandableIDs)
        } else {
            let changedIndices: IndexSet = switch update {
            case let .tailChange(index): IndexSet(integer: index)
            case let .rowChanges(indices): indices
            case .unchanged, .append, .prepend, .reloadAll: []
            }
            for index in changedIndices where newItems.indices.contains(index) {
                if !newItems[index].kind.isCollapsibleActivity {
                    expandedItemIDs.remove(newItems[index].id)
                }
            }
        }

        var appendProjectionChange: AppendProjectionChange?
        var prependProjectionChange: PrependProjectionChange?
        var tailProjectionChange: TailProjectionChange?
        let viewportAnchor: ViewportAnchor? = if case .prepend = update {
            captureViewportAnchor()
        } else {
            nil
        }
        let groupingStructureChanged: Bool
        let displayMappingChanged: Bool
        if case let .append(appendedRange) = update {
            appendProjectionChange = appendProjection(
                oldItems: oldItems,
                newItems: newItems,
                appendedRange: appendedRange
            )
            groupingStructureChanged = false
            // The append path updates just the affected index-map suffix.
            displayMappingChanged = false
        } else if case let .prepend(prependedRange) = update {
            prependProjectionChange = prependProjection(
                oldItems: oldItems,
                newItems: newItems,
                prependedRange: prependedRange
            )
            groupingStructureChanged = false
            displayMappingChanged = false
        } else if case let .tailChange(index) = update,
                  TranscriptActivityGrouping.requiresProjectionRebuild(
                    for: update,
                    from: oldItems,
                    to: newItems
                  ) {
            tailProjectionChange = replaceChangedTailProjection(
                oldItems: oldItems,
                newItems: newItems,
                changedIndex: index
            )
            groupingStructureChanged = false
            displayMappingChanged = false
        } else if !TranscriptActivityGrouping.requiresProjectionRebuild(
            for: update,
            from: oldItems,
            to: newItems
        ) {
            // SwiftUI can revisit this controller because unrelated task state
            // changed. An unchanged revision proves the transcript projection
            // is still valid, so avoid adding another full-history grouping
            // pass to the controller's existing update work.
            groupingStructureChanged = false
            displayMappingChanged = false
        } else {
            let oldGroupStructure = activityGroups.map(\.structureKey)
            let oldDisplayRowIDs = displayRows.map(\.id)
            let newGroups = TranscriptActivityGrouping.groups(for: newItems)
            expandedActivityGroupIDs.formIntersection(Set(newGroups.map(\.id)))
            activityGroups.replaceAll(with: newGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: newGroups))
            groupingStructureChanged = oldGroupStructure != newGroups.map(\.structureKey)
            displayMappingChanged = groupingStructureChanged
                || oldDisplayRowIDs != displayRows.map(\.id)
        }

        layoutState.prepare(for: update, newItems: newItems)
        if displayMappingChanged {
            rebuildDisplayIndex()
        }
        items = newItems
        itemsRevision = newRevision

        // Publish the final data-source state before entering the collection
        // transaction. Every incremental operation below (including a
        // pending-row insert/delete) is then validated against the same new
        // row count. The old pending state remains captured in
        // `pendingResponseChange` for index-path planning.
        pendingResponse = newPendingResponse

        if let appendProjectionChange {
            applyAppendProjectionChange(
                appendProjectionChange,
                pendingResponseChange: pendingResponseChange,
                additionalReloadIndices: retryActionReloadIndices
            )
        } else if let prependProjectionChange {
            applyPrependProjectionChange(
                prependProjectionChange,
                anchor: viewportAnchor,
                pendingResponseChange: pendingResponseChange,
                additionalReloadIndices: retryActionReloadIndices
            )
        } else if let tailProjectionChange {
            applyTailProjectionChange(
                tailProjectionChange,
                pendingResponseChange: pendingResponseChange,
                additionalReloadIndices: retryActionReloadIndices
            )
        } else if groupingStructureChanged {
            collectionView.reloadData()
        } else {
            switch update {
            case .unchanged:
                applySimpleCollectionUpdate(
                    pendingResponseChange: pendingResponseChange,
                    reloadIndices: retryActionReloadIndices
                )
            case let .tailChange(index):
                var reloadIndices = retryActionReloadIndices
                reloadIndices.insert(index)
                applySimpleCollectionUpdate(
                    pendingResponseChange: pendingResponseChange,
                    reloadIndices: reloadIndices
                )
            case let .rowChanges(indices):
                var reloadIndices = retryActionReloadIndices
                reloadIndices.formUnion(indices)
                applySimpleCollectionUpdate(
                    pendingResponseChange: pendingResponseChange,
                    reloadIndices: reloadIndices
                )
            case .append:
                // Handled by the incremental projection branch above.
                break
            case .prepend:
                // Handled by the incremental projection branch above.
                break
            case .reloadAll:
                collectionView.reloadData()
            }
        }

        let prependedHistory = if case .prepend = update { true } else { false }
        if !prependedHistory && (shouldFollow || oldItems.isEmpty || pendingResponse.isVisible) {
            scheduleFollowScroll()
        }
        refreshVisibleMessageEditActions()
    }

    private func scheduleFollowScroll() {
        guard !hasScheduledFollowScroll else { return }
        hasScheduledFollowScroll = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledFollowScroll = false
            self.scrollToBottom()
        }
    }

    /// Applies one coherent AppKit transaction for a transcript mutation and
    /// the presentation-only pending row. In particular, a streamed first
    /// token may insert transcript rows while removing the old waiting row at
    /// the same tail index; issuing those as separate collection mutations
    /// leaves NSCollectionView with an invalid intermediate item count.
    private func performCollectionBatch(
        pendingResponseChange change: PendingResponseChange,
        hasUpdates: Bool,
        updates: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let oldVisible = change.old.isVisible
        let newVisible = change.new.isVisible
        let oldDisplayCount = change.oldDisplayCount
        let newDisplayCount = displayRows.count
        let pendingVisibilityChanged = oldVisible != newVisible
        let canReloadLabelInBatch = change.labelChanged
            && !pendingVisibilityChanged
            && oldDisplayCount == newDisplayCount
        let hasPendingOperation = pendingVisibilityChanged || canReloadLabelInBatch

        guard hasPendingOperation || hasUpdates else {
            completion?()
            return
        }

        let retirementToken: UInt64?
        if oldVisible, !newVisible {
            nextPendingResponseRetirementToken &+= 1
            let token = nextPendingResponseRetirementToken
            retiringPendingResponses.append(RetiringPendingResponse(
                token: token,
                displayIndex: oldDisplayCount,
                response: change.old
            ))
            retirementToken = token
        } else {
            retirementToken = nil
        }

        collectionView.performBatchUpdates({ [weak self] in
            guard let self else { return }
            updates()
            if oldVisible, !newVisible {
                self.collectionView.deleteItems(at: [
                    IndexPath(item: oldDisplayCount, section: 0),
                ])
            } else if !oldVisible, newVisible {
                self.collectionView.insertItems(at: [
                    IndexPath(item: newDisplayCount, section: 0),
                ])
            }
            if canReloadLabelInBatch {
                self.collectionView.reloadItems(at: [
                    IndexPath(item: newDisplayCount, section: 0),
                ])
            }
        }, completionHandler: { [weak self] _ in
            guard let self else {
                completion?()
                return
            }
            // If transcript rows shifted the pending row, reload its new
            // position only after the structural batch has settled. This is
            // a content refresh, not a second topology mutation.
            if change.labelChanged,
               !canReloadLabelInBatch,
               newVisible,
               self.pendingResponse == change.new {
                self.collectionView.reloadItems(at: [
                    IndexPath(item: self.displayRows.count, section: 0),
                ])
            }
            if let retirementToken {
                // The completion can precede AppKit's final layout request for
                // the deleted row. Close that window on the next main-loop
                // turn, once the batch's immediate layout work has drained.
                DispatchQueue.main.async { [weak self] in
                    self?.retiringPendingResponses.removeAll {
                        $0.token == retirementToken
                    }
                }
            }
            completion?()
        })
    }

    private func applySimpleCollectionUpdate(
        pendingResponseChange change: PendingResponseChange,
        reloadIndices: IndexSet = []
    ) {
        let indexPaths = reloadIndexPaths(for: reloadIndices)
        performCollectionBatch(
            pendingResponseChange: change,
            hasUpdates: !indexPaths.isEmpty
        ) { [weak self] in
            guard let self else { return }
            if !indexPaths.isEmpty {
                self.collectionView.reloadItems(at: indexPaths)
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayRows.count + (pendingResponse.isVisible ? 1 : 0)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        if let response = pendingResponseForDataSource(at: indexPath.item) {
            return makePendingResponseItem(
                in: collectionView,
                at: indexPath,
                response: response
            )
        }

        switch displayRows[indexPath.item] {
        case let .activityGroup(group):
            let item = collectionView.makeItem(
                withIdentifier: Self.activityGroupIdentifier,
                for: indexPath
            )
            (item as? TranscriptActivityGroupCollectionItem)?.configure(
                group: group,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                onToggle: { [weak self] expanded in
                    self?.setActivityGroupExpanded(expanded, for: group.id)
                }
            )
            return item
        case let .item(index):
            let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
            guard let transcriptItem = item as? TranscriptCollectionItem,
                  items.indices.contains(index) else { return item }
            let timelineItem = items[index]
            transcriptItem.configure(
                with: timelineItem,
                isExpanded: isExpanded(timelineItem),
                isEditable: timelineItem.id == editableUserMessageID,
                isRetryable: timelineItem.id == retryableFailedResponseItemID,
                onEdit: { [weak self] in
                    self?.onEditUserMessage(timelineItem.id)
                },
                onRetry: { [weak self] in
                    self?.onRetryFailedResponse(timelineItem.id)
                },
                onToggle: { [weak self] expanded in
                    self?.setExpanded(expanded, for: timelineItem.id)
                }
            )
            return transcriptItem
        }
    }

    func pendingResponseForDataSource(at displayIndex: Int) -> TranscriptPendingResponse? {
        if pendingResponse.isVisible, displayIndex == displayRows.count {
            return pendingResponse
        }
        // A newly inserted transcript row can reuse the old pending row's
        // index. In that case the real transcript row is authoritative; the
        // tombstone is only for an index outside the new projection.
        guard !displayRows.indices.contains(displayIndex) else { return nil }
        return retiringPendingResponses.last(where: {
            $0.displayIndex == displayIndex
        })?.response
    }

    private func makePendingResponseItem(
        in collectionView: NSCollectionView,
        at indexPath: IndexPath,
        response: TranscriptPendingResponse
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: Self.pendingItemIdentifier,
            for: indexPath
        )
        (item as? TranscriptPendingCollectionItem)?.configure(label: response.label)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = flowMetrics.itemWidth
        if pendingResponseForDataSource(at: indexPath.item) != nil {
            return NSSize(width: width, height: TranscriptPendingResponseView.rowHeight)
        }
        switch displayRows[indexPath.item] {
        case .activityGroup:
            return NSSize(width: width, height: TranscriptActivityGroupView.rowHeight)
        case let .item(index):
            let item = items[index]
            let expanded = isExpanded(item)
            let retryable = item.id == retryableFailedResponseItemID
            if retryable {
                return NSSize(
                    width: width,
                    height: TranscriptCellView.height(
                        for: item,
                        width: width,
                        isExpanded: expanded,
                        isRetryable: true
                    )
                )
            }
            return NSSize(
                width: width,
                height: layoutState.height(for: item, width: width, isExpanded: expanded) {
                    TranscriptCellView.height(for: item, width: width, isExpanded: expanded)
                }
            )
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let metrics = flowMetrics
        return NSEdgeInsets(
            top: 18,
            left: metrics.leadingInset,
            bottom: 24,
            right: metrics.trailingInset
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if layoutState.readableWidthDidChange(to: readableWidth) {
            layout.invalidateLayout()
        }
        // The transcript's flexible lower-third gravity depends on the clip
        // view height, not the collection document height.  AppKit does not
        // always invalidate a document layout when the hosting window changes
        // height, so explicitly invalidate once per distinct viewport size.
        let viewportHeight = scrollView.contentView.bounds.height
        if viewportHeight.isFinite,
           observedViewportHeight != viewportHeight {
            observedViewportHeight = viewportHeight
            layout.invalidateLayout()
        }
    }

    private var readableWidth: CGFloat {
        flowMetrics.itemWidth
    }

    private var flowMetrics: TranscriptFlowMetrics {
        // During an NSWindow resize, the clip view and its document view can
        // report their new widths in separate AppKit layout passes. Size rows
        // against the smaller width so cached attributes never overflow the
        // viewport in that transition.
        TranscriptFlowMetrics(
            collectionWidth: min(
                collectionView.bounds.width,
                max(
                    0,
                    scrollView.contentView.bounds.width
                        - scrollView.contentInsets.left
                        - scrollView.contentInsets.right
                )
            )
        )
    }

    private var isNearBottom: Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return documentView.bounds.height - visibleMaxY < 48
    }

    private func makeDisplayRows<Groups: Collection>(
        items: [TimelineItem],
        groups: Groups
    ) -> [DisplayRow] where Groups.Element == TranscriptActivityGroup {
        makeDisplayRows(items: items, groups: groups, startingAt: 0)
    }

    private func makeDisplayRows<Groups: Collection>(
        items: [TimelineItem],
        groups: Groups,
        startingAt initialIndex: Int,
        endingAt requestedEndIndex: Int? = nil
    ) -> [DisplayRow] where Groups.Element == TranscriptActivityGroup {
        var groupsByStart: [Int: TranscriptActivityGroup] = [:]
        groupsByStart.reserveCapacity(groups.count)
        for group in groups {
            groupsByStart[group.range.lowerBound] = group
        }

        var rows: [DisplayRow] = []
        let endIndex = min(items.count, max(initialIndex, requestedEndIndex ?? items.count))
        rows.reserveCapacity(max(0, endIndex - initialIndex))
        var index = initialIndex
        while index < endIndex {
            if let group = groupsByStart[index] {
                // Keep the disclosure row mounted while expanded so the user
                // can collapse the rollup again after inspecting its child
                // events. The original children are inserted immediately
                // below it only while the group is open.
                rows.append(.activityGroup(group))
                if expandedActivityGroupIDs.contains(group.id) {
                    rows.append(contentsOf: group.range.map { .item(index: $0) })
                }
                index = group.range.upperBound
            } else {
                rows.append(.item(index: index))
                index += 1
            }
        }
        return rows
    }

    /// Extends the projection above the current page without touching the
    /// mounted suffix. Groups intentionally stop at the page boundary: joining
    /// two routine-activity runs across that boundary would mutate the first
    /// visible row and defeat stable incremental insertion.
    private func prependProjection(
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        prependedRange: Range<Int>
    ) -> PrependProjectionChange {
        guard prependedRange.lowerBound == 0,
              prependedRange.upperBound > 0,
              newItems.count == oldItems.count + prependedRange.count else {
            let rebuiltGroups = TranscriptActivityGrouping.groups(for: newItems)
            activityGroups.replaceAll(with: rebuiltGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: rebuiltGroups))
            rebuildDisplayIndex()
            return PrependProjectionChange(insertedDisplayCount: 0, requiresReload: true)
        }

        let offset = prependedRange.count
        let prefixItems = Array(newItems[prependedRange])
        let prefixGroups = TranscriptActivityGrouping.groups(for: prefixItems)
        let prefixRows = makeDisplayRows(
            items: newItems,
            groups: prefixGroups[...],
            startingAt: 0,
            endingAt: offset
        )

        activityGroups.prepend(prefixGroups, itemOffset: offset)
        displayRows.prepend(prefixRows, itemOffset: offset)
        prependInstrumentation.projectedPrefixItemCount += prefixItems.count
        prependInstrumentation.projectedPrefixGroupCount += prefixGroups.count
        displayIndexIsDirty = true
        deferredItemIndexOffset += offset
        deferredDisplayIndexOffset += prefixRows.count
        return PrependProjectionChange(
            insertedDisplayCount: prefixRows.count,
            requiresReload: false
        )
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        let visiblePaths = collectionView.indexPathsForVisibleItems()
            .filter { displayRows.indices.contains($0.item) }
            .sorted { $0.item < $1.item }
        guard let path = visiblePaths.first,
              let attributes = collectionView.layoutAttributesForItem(at: path),
              let rowID = stableID(for: displayRows[path.item], in: items) else { return nil }
        return ViewportAnchor(
            rowID: rowID,
            displayIndex: path.item,
            offsetFromViewportTop: attributes.frame.minY - scrollView.contentView.bounds.minY
        )
    }

    private func stableID(for row: DisplayRow, in items: [TimelineItem]) -> String? {
        switch row {
        case let .item(index):
            guard items.indices.contains(index) else { return nil }
            return "item:\(items[index].id)"
        case let .activityGroup(group):
            return "group:\(group.id)"
        }
    }

    private func applyPrependProjectionChange(
        _ change: PrependProjectionChange,
        anchor: ViewportAnchor?,
        pendingResponseChange: PendingResponseChange,
        additionalReloadIndices: IndexSet = []
    ) {
        guard !change.requiresReload else {
            prependInstrumentation.fullReloadCount += 1
            collectionView.reloadData()
            restoreViewport(anchor)
            return
        }
        guard change.insertedDisplayCount > 0 else {
            performCollectionBatch(
                pendingResponseChange: pendingResponseChange,
                hasUpdates: false,
                updates: {},
                completion: { [weak self] in
                    self?.reloadRows(additionalReloadIndices)
                    self?.restoreViewport(anchor)
                }
            )
            return
        }

        let insertedPaths = Set(
            (0..<change.insertedDisplayCount).map { IndexPath(item: $0, section: 0) }
        )
        prependInstrumentation.insertedDisplayRowCount += change.insertedDisplayCount
        performCollectionBatch(
            pendingResponseChange: pendingResponseChange,
            hasUpdates: true,
            updates: { [weak self] in
                self?.collectionView.insertItems(at: insertedPaths)
            }
        ) { [weak self] in
            guard let self else { return }
            // Item indices already describe the final, prepended projection.
            // Reload only after the structural batch settles so AppKit never
            // receives the shifted row as both an insertion and a reload.
            self.reloadRows(additionalReloadIndices)
            self.restoreViewport(
                anchor,
                expectedDisplayIndexOffset: change.insertedDisplayCount
            )
        }
    }

    private func restoreViewport(
        _ anchor: ViewportAnchor?,
        expectedDisplayIndexOffset: Int = 0
    ) {
        guard let anchor else { return }
        // AppKit may complete a batch before its flow layout has produced the
        // inserted rows' final attributes. Defer one main-loop turn so the
        // stable old row can be placed at precisely its previous visual offset.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let expectedDisplayIndex = anchor.displayIndex + expectedDisplayIndexOffset
            let displayIndex: Int?
            if self.displayRows.indices.contains(expectedDisplayIndex),
               self.stableID(
                   for: self.displayRows[expectedDisplayIndex],
                   in: self.items
               ) == anchor.rowID {
                displayIndex = expectedDisplayIndex
            } else {
                // The fallback is reserved for a defensive full reload. A
                // valid prepend knows exactly how many display rows were
                // inserted and restores the anchor without scanning history.
                self.prependInstrumentation.anchorFallbackScanCount += 1
                displayIndex = self.displayRows.firstIndex(where: {
                    self.stableID(for: $0, in: self.items) == anchor.rowID
                })
            }
            guard let displayIndex,
                  let attributes = self.collectionView.layoutAttributesForItem(
                      at: IndexPath(item: displayIndex, section: 0)
                  ) else { return }

            let clipView = self.scrollView.contentView
            var proposedBounds = clipView.bounds
            proposedBounds.origin.y = attributes.frame.minY - anchor.offsetFromViewportTop
            let constrained = clipView.constrainBoundsRect(proposedBounds)
            clipView.scroll(to: constrained.origin)
            self.scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func appendProjection(
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        appendedRange: Range<Int>
    ) -> AppendProjectionChange {
        let oldDisplayCount = displayRows.count
        let hadDeferredDisplayIndex = displayIndexIsDirty
        var groupingInstrumentation = TranscriptActivityGrouping.AppendInstrumentation()
        guard let mutation = TranscriptActivityGrouping.appendMutation(
            for: activityGroups,
            oldItems: oldItems,
            newItems: newItems,
            appendedRange: appendedRange,
            instrumentation: &groupingInstrumentation
        ) else {
            let rebuiltGroups = TranscriptActivityGrouping.groups(for: newItems)
            activityGroups.replaceAll(with: rebuiltGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: rebuiltGroups))
            rebuildDisplayIndex()
            return AppendProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                requiresReload: true
            )
        }
        prependInstrumentation.tailGroupingInspectedItemCount +=
            groupingInstrumentation.inspectedItemCount
        let result = mutation.result
        activityGroups.removeSubrange(result.groupStart..<activityGroups.endIndex)
        activityGroups.append(contentsOf: mutation.replacementGroups)
        let displayStart: Int
        if result.itemStart == oldItems.count {
            displayStart = oldDisplayCount
        } else if let groupIndex = deferredGroupDisplayIndex(for: result.itemStart) {
            displayStart = groupIndex
        } else if let itemIndex = deferredDisplayIndex(for: result.itemStart) {
            displayStart = itemIndex
        } else {
            let rebuiltGroups = TranscriptActivityGrouping.groups(for: newItems)
            activityGroups.replaceAll(with: rebuiltGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: rebuiltGroups))
            rebuildDisplayIndex()
            return AppendProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                requiresReload: true
            )
        }

        let oldTailIDs = displayRows[displayStart...].map(\.id)
        displayRows.removeSubrange(displayStart..<displayRows.endIndex)
        let tailRows = makeDisplayRows(
            items: newItems,
            groups: activityGroups[result.groupStart...],
            startingAt: result.itemStart
        )
        displayRows.append(contentsOf: tailRows)
        let newTailIDs = tailRows.map(\.id)
        updateDisplayIndexSuffix(
            fromDisplayIndex: displayStart,
            itemIndexStart: result.itemStart,
            oldItemCount: oldItems.count,
            preservingDeferredOffsets: hadDeferredDisplayIndex
        )

        return AppendProjectionChange(
            displayStart: displayStart,
            oldDisplayCount: oldDisplayCount,
            oldTailIDs: oldTailIDs,
            newTailIDs: newTailIDs,
            requiresReload: false
        )
    }

    private func applyAppendProjectionChange(
        _ change: AppendProjectionChange,
        pendingResponseChange: PendingResponseChange,
        additionalReloadIndices: IndexSet = []
    ) {
        applySuffixProjectionChange(
            displayStart: change.displayStart,
            oldDisplayCount: change.oldDisplayCount,
            oldTailIDs: change.oldTailIDs,
            newTailIDs: change.newTailIDs,
            requiresReload: change.requiresReload,
            pendingResponseChange: pendingResponseChange,
            additionalReloadIndices: additionalReloadIndices
        )
    }

    /// Reconciles only the mutable display suffix. The common prefix stays
    /// mounted and is reloaded atomically when its rollup summary changed;
    /// the remaining old/new rows are deleted and inserted in the same AppKit
    /// transaction. This covers lone-activity -> rollup, live-tail joining an
    /// existing rollup, and the bounded eight -> nine activity transition.
    private func applySuffixProjectionChange(
        displayStart: Int,
        oldDisplayCount: Int,
        oldTailIDs: [String],
        newTailIDs: [String],
        requiresReload: Bool,
        pendingResponseChange: PendingResponseChange,
        additionalReloadIndices: IndexSet = []
    ) {
        guard !requiresReload,
              oldDisplayCount == displayStart + oldTailIDs.count,
              displayRows.count == displayStart + newTailIDs.count else {
            prependInstrumentation.projectionFullReloadCount += 1
            collectionView.reloadData()
            return
        }

        if oldTailIDs == newTailIDs {
            var paths = Set(
                (displayStart..<displayRows.count).map {
                    IndexPath(item: $0, section: 0)
                }
            )
            paths.formUnion(reloadIndexPaths(for: additionalReloadIndices))
            performCollectionBatch(
                pendingResponseChange: pendingResponseChange,
                hasUpdates: !paths.isEmpty
            ) { [weak self] in
                guard let self, !paths.isEmpty else { return }
                self.collectionView.reloadItems(at: paths)
            }
            return
        }

        var commonPrefixCount = 0
        while commonPrefixCount < min(oldTailIDs.count, newTailIDs.count),
              oldTailIDs[commonPrefixCount] == newTailIDs[commonPrefixCount] {
            commonPrefixCount += 1
        }

        let replacementStart = displayStart + commonPrefixCount
        let deletedPaths = Set(
            (replacementStart..<oldDisplayCount).map {
                IndexPath(item: $0, section: 0)
            }
        )
        let insertedPaths = Set(
            (replacementStart..<displayRows.count).map {
                IndexPath(item: $0, section: 0)
            }
        )
        var reloadPaths = Set(
            (displayStart..<replacementStart).map {
                IndexPath(item: $0, section: 0)
            }
        )
        // Rows inside the replacement suffix are recreated by delete/insert;
        // only unchanged prefix paths need the additional retry-state reload.
        reloadPaths.formUnion(
            reloadIndexPaths(for: additionalReloadIndices).filter {
                $0.item < replacementStart
            }
        )
        let hasSuffixUpdates = !deletedPaths.isEmpty
            || !insertedPaths.isEmpty
            || !reloadPaths.isEmpty
        if hasSuffixUpdates {
            prependInstrumentation.suffixBatchUpdateCount += 1
        }
        performCollectionBatch(
            pendingResponseChange: pendingResponseChange,
            hasUpdates: hasSuffixUpdates
        ) { [weak self] in
            guard let self else { return }
            if !deletedPaths.isEmpty {
                self.collectionView.deleteItems(at: deletedPaths)
            }
            if !insertedPaths.isEmpty {
                self.collectionView.insertItems(at: insertedPaths)
            }
            if !reloadPaths.isEmpty {
                self.collectionView.reloadItems(at: reloadPaths)
            }
        }
    }

    private func deferredDisplayIndex(for itemIndex: Int) -> Int? {
        if let baseIndex = displayIndexByItemIndex[itemIndex - deferredItemIndexOffset] {
            let candidate = baseIndex + deferredDisplayIndexOffset
            if displayRow(at: candidate, contains: itemIndex, groupOnly: false) {
                return candidate
            }
        }
        return displayIndexNearTail(for: itemIndex, groupOnly: false)
    }

    private func deferredGroupDisplayIndex(for itemIndex: Int) -> Int? {
        if let baseIndex = groupDisplayIndexByItemIndex[itemIndex - deferredItemIndexOffset] {
            let candidate = baseIndex + deferredDisplayIndexOffset
            if displayRow(at: candidate, contains: itemIndex, groupOnly: true) {
                return candidate
            }
        }
        return displayIndexNearTail(for: itemIndex, groupOnly: true)
    }

    private func displayRow(at displayIndex: Int, contains itemIndex: Int, groupOnly: Bool) -> Bool {
        guard displayRows.indices.contains(displayIndex) else { return false }
        switch displayRows[displayIndex] {
        case let .item(index):
            return !groupOnly && index == itemIndex
        case let .activityGroup(group):
            return group.range.contains(itemIndex)
        }
    }

    private func displayIndexNearTail(for itemIndex: Int, groupOnly: Bool) -> Int? {
        prependInstrumentation.nearTailLookupCount += 1
        guard !displayRows.isEmpty else { return nil }
        var displayIndex = displayRows.index(before: displayRows.endIndex)
        var inspectedRowCount = 0
        while inspectedRowCount < Self.maximumNearTailLookupRows {
            inspectedRowCount += 1
            prependInstrumentation.nearTailInspectedRowCount += 1
            switch displayRows[displayIndex] {
            case let .item(index):
                if !groupOnly, index == itemIndex { return displayIndex }
                if index < itemIndex { return nil }
            case let .activityGroup(group):
                if group.range.contains(itemIndex) { return displayIndex }
                if group.range.upperBound <= itemIndex { return nil }
            }
            guard displayIndex > displayRows.startIndex else { return nil }
            displayIndex = displayRows.index(before: displayIndex)
        }
        prependInstrumentation.nearTailLookupBudgetExceededCount += 1
        return nil
    }

    private func replaceChangedTailProjection(
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        changedIndex: Int
    ) -> TailProjectionChange {
        let oldDisplayCount = displayRows.count
        let hadDeferredDisplayIndex = displayIndexIsDirty
        let oldGroupCount = activityGroups.count
        let previousLastGroupID = activityGroups.last?.id
        var groupingInstrumentation = TranscriptActivityGrouping.AppendInstrumentation()
        guard let mutation = TranscriptActivityGrouping.replaceChangedTailMutation(
            in: activityGroups,
            oldItems: oldItems,
            newItems: newItems,
            changedIndex: changedIndex,
            instrumentation: &groupingInstrumentation
        ) else {
            let rebuiltGroups = TranscriptActivityGrouping.groups(for: newItems)
            activityGroups.replaceAll(with: rebuiltGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: rebuiltGroups))
            rebuildDisplayIndex()
            return TailProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                requiresReload: true
            )
        }
        prependInstrumentation.tailGroupingInspectedItemCount +=
            groupingInstrumentation.inspectedItemCount
        let result = mutation.result
        activityGroups.removeSubrange(result.groupStart..<activityGroups.endIndex)
        activityGroups.append(contentsOf: mutation.replacementGroups)
        if result.groupStart < oldGroupCount,
           let previousLastGroupID,
           !activityGroups[result.groupStart...].contains(where: { $0.id == previousLastGroupID }) {
            expandedActivityGroupIDs.remove(previousLastGroupID)
        }

        let displayStart: Int
        if let groupIndex = deferredGroupDisplayIndex(for: result.itemStart) {
            displayStart = groupIndex
        } else if let itemIndex = deferredDisplayIndex(for: result.itemStart) {
            displayStart = itemIndex
        } else {
            let rebuiltGroups = TranscriptActivityGrouping.groups(for: newItems)
            activityGroups.replaceAll(with: rebuiltGroups)
            displayRows.replaceAll(with: makeDisplayRows(items: newItems, groups: rebuiltGroups))
            rebuildDisplayIndex()
            return TailProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                requiresReload: true
            )
        }

        let oldTailIDs = displayRows[displayStart...].map(\.id)
        displayRows.removeSubrange(displayStart..<displayRows.endIndex)
        let tailRows = makeDisplayRows(
            items: newItems,
            groups: activityGroups[result.groupStart...],
            startingAt: result.itemStart
        )
        displayRows.append(contentsOf: tailRows)
        updateDisplayIndexSuffix(
            fromDisplayIndex: displayStart,
            itemIndexStart: result.itemStart,
            oldItemCount: oldItems.count,
            preservingDeferredOffsets: hadDeferredDisplayIndex
        )

        return TailProjectionChange(
            displayStart: displayStart,
            oldDisplayCount: oldDisplayCount,
            oldTailIDs: oldTailIDs,
            newTailIDs: tailRows.map(\.id),
            requiresReload: false
        )
    }

    private func applyTailProjectionChange(
        _ change: TailProjectionChange,
        pendingResponseChange: PendingResponseChange,
        additionalReloadIndices: IndexSet = []
    ) {
        applySuffixProjectionChange(
            displayStart: change.displayStart,
            oldDisplayCount: change.oldDisplayCount,
            oldTailIDs: change.oldTailIDs,
            newTailIDs: change.newTailIDs,
            requiresReload: change.requiresReload,
            pendingResponseChange: pendingResponseChange,
            additionalReloadIndices: additionalReloadIndices
        )
    }

    private func rebuildDisplayIndex() {
        prependInstrumentation.displayIndexRebuildCount += 1
        displayIndexByItemIndex.removeAll(keepingCapacity: true)
        groupDisplayIndexByItemIndex.removeAll(keepingCapacity: true)
        for (displayIndex, row) in displayRows.enumerated() {
            switch row {
            case let .item(index):
                displayIndexByItemIndex[index] = displayIndex
            case let .activityGroup(group):
                for index in group.range {
                    groupDisplayIndexByItemIndex[index] = displayIndex
                    if !expandedActivityGroupIDs.contains(group.id) {
                        // A collapsed group deliberately maps every child to
                        // its one visible row. This lets a streamed child
                        // invalidate the summary without exposing a second
                        // collection row.
                        displayIndexByItemIndex[index] = displayIndex
                    }
                }
            }
        }
        displayIndexIsDirty = false
        deferredItemIndexOffset = 0
        deferredDisplayIndexOffset = 0
    }

    private func ensureDisplayIndex() {
        guard displayIndexIsDirty else { return }
        rebuildDisplayIndex()
    }

    private func updateDisplayIndexSuffix(
        fromDisplayIndex displayStart: Int,
        itemIndexStart: Int,
        oldItemCount: Int,
        preservingDeferredOffsets: Bool
    ) {
        let itemOffset = preservingDeferredOffsets ? deferredItemIndexOffset : 0
        let displayOffset = preservingDeferredOffsets ? deferredDisplayIndexOffset : 0
        let normalizedItemStart = itemIndexStart - itemOffset
        let normalizedOldItemCount = oldItemCount - itemOffset
        if itemIndexStart < oldItemCount {
            for index in normalizedItemStart..<normalizedOldItemCount {
                displayIndexByItemIndex.removeValue(forKey: index)
                groupDisplayIndexByItemIndex.removeValue(forKey: index)
            }
        }
        for displayIndex in displayStart..<displayRows.count {
            switch displayRows[displayIndex] {
            case let .item(index):
                displayIndexByItemIndex[index - itemOffset] = displayIndex - displayOffset
            case let .activityGroup(group):
                for index in group.range {
                    groupDisplayIndexByItemIndex[index - itemOffset] = displayIndex - displayOffset
                    if !expandedActivityGroupIDs.contains(group.id) {
                        displayIndexByItemIndex[index - itemOffset] = displayIndex - displayOffset
                    }
                }
            }
        }
        if !preservingDeferredOffsets {
            displayIndexIsDirty = false
            deferredItemIndexOffset = 0
            deferredDisplayIndexOffset = 0
        }
    }

    private func reloadIndexPaths(for indices: IndexSet) -> Set<IndexPath> {
        guard !indices.isEmpty else { return [] }
        if displayIndexIsDirty {
            prependInstrumentation.deferredReloadLookupCount += indices.count
        }

        func resolveUsingDeferredOffsets() -> (displayIndices: IndexSet, unresolved: Bool) {
            var displayIndices = IndexSet()
            var unresolved = false
            for index in indices {
                let itemDisplayIndex = deferredDisplayIndex(for: index)
                // Only routine activity can be a rollup child. Avoid an
                // unnecessary bounded tail scan for plans, assistant text,
                // approvals, and other independently displayed rows.
                let groupDisplayIndex: Int? = if items.indices.contains(index),
                                                 items[index].kind.isRoutineActivity {
                    deferredGroupDisplayIndex(for: index)
                } else {
                    nil
                }
                if let itemDisplayIndex {
                    displayIndices.insert(itemDisplayIndex)
                }
                // A child's title can contribute to the semantic rollup.
                // Refresh its header too when the group is expanded.
                if let groupDisplayIndex {
                    displayIndices.insert(groupDisplayIndex)
                }
                if itemDisplayIndex == nil, groupDisplayIndex == nil {
                    unresolved = true
                }
            }
            return (displayIndices, unresolved)
        }

        var resolution = resolveUsingDeferredOffsets()
        if resolution.unresolved, displayIndexIsDirty {
            // Arbitrary old-row mutations are uncommon but must remain
            // correct. Only those fall back to rebuilding the full maps;
            // streamed tail rows resolve through offsets or the hard-bounded
            // near-tail lookup above.
            ensureDisplayIndex()
            resolution = (
                IndexSet(indices.flatMap { index in
                    [displayIndexByItemIndex[index], groupDisplayIndexByItemIndex[index]]
                        .compactMap { $0 }
                }),
                false
            )
        }
        guard !resolution.displayIndices.isEmpty else { return [] }
        return Set(
            resolution.displayIndices.map { IndexPath(item: $0, section: 0) }
        )
    }

    private func reloadRows(_ indices: IndexSet) {
        let indexPaths = reloadIndexPaths(for: indices)
        guard !indexPaths.isEmpty else { return }
        // Reloading the items is the single layout mutation. A separate manual
        // invalidation here is re-entrant when this update is driven by an
        // `NSHostingView` layout pass and has caused production crashes.
        collectionView.reloadItems(at: indexPaths)
    }

    private func refreshVisibleMessageEditActions() {
        for case let item as TranscriptCollectionItem in collectionView.visibleItems() {
            item.updateEditAction(
                editableUserMessageID: editableUserMessageID,
                retryableFailedResponseItemID: retryableFailedResponseItemID,
                onEdit: { [weak self] messageID in
                    self?.onEditUserMessage(messageID)
                },
                onRetry: { [weak self] messageID in
                    self?.onRetryFailedResponse(messageID)
                }
            )
        }
    }

    private func isExpanded(_ item: TimelineItem) -> Bool {
        item.kind.isCollapsibleActivity ? expandedItemIDs.contains(item.id) : true
    }

    private func setExpanded(_ expanded: Bool, for itemID: String) {
        ensureDisplayIndex()
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].kind.isCollapsibleActivity else { return }

        if expanded {
            expandedItemIDs.insert(itemID)
        } else {
            expandedItemIDs.remove(itemID)
        }
        layoutState.invalidate(itemID: itemID)
        reloadRows(IndexSet(integer: index))
    }

    private func setActivityGroupExpanded(_ expanded: Bool, for groupID: String) {
        guard activityGroups.contains(where: { $0.id == groupID }) else { return }
        if expanded {
            expandedActivityGroupIDs.insert(groupID)
        } else {
            expandedActivityGroupIDs.remove(groupID)
        }

        let oldIDs = displayRows.map(\.id)
        displayRows.replaceAll(with: makeDisplayRows(items: items, groups: activityGroups))
        rebuildDisplayIndex()
        guard oldIDs != displayRows.map(\.id) else { return }

        collectionView.reloadData()
        // Do not move the viewport when opening an older group; the expanded
        // children appear in place and the user can keep reading from there.
    }

    private func scrollToBottom() {
        let itemCount = displayRows.count + (pendingResponse.isVisible ? 1 : 0)
        guard itemCount > 0 else { return }
        collectionView.scrollToItems(
            at: [IndexPath(item: itemCount - 1, section: 0)],
            scrollPosition: .bottom
        )
    }
}

/// Colors and geometry for the presentation-only response-status row. Keeping
/// the palette in one small value type makes the contrast contract explicit
/// and lets hosted tests verify both appearances without relying on whatever
/// appearance happens to be active for the test process.
enum TranscriptPendingResponsePresentation {
    static func colors(for appearance: NSAppearance?) -> (tint: NSColor, text: NSColor) {
        (
            OnyxTheme.electricNSColor(for: appearance),
            OnyxTheme.readingNSColor(for: appearance)
        )
    }
}

final class TranscriptPendingResponseView: NSView {
    static let rowHeight: CGFloat = 34

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Working")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: OnyxTypography.reading, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        addSubview(spinner)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Assistant response status")
        setAccessibilityValue("Working")
        applyThinkingAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Keep the status copy on the same reading axis as assistant replies
        // and compact activity labels. The spinner sits in the quiet icon
        // gutter instead of pushing the message itself farther into the row.
        let leading: CGFloat = 0
        let spinnerSize: CGFloat = 14
        spinner.frame = NSRect(
            x: leading,
            y: floor((bounds.height - spinnerSize) / 2),
            width: spinnerSize,
            height: spinnerSize
        )
        let labelHeight = min(
            bounds.height,
            ceil(label.font?.boundingRectForFont.height ?? 16) + 4
        )
        label.frame = NSRect(
            x: OnyxWorkspaceMetrics.conversationTextInset,
            y: floor((bounds.height - labelHeight) / 2),
            width: max(0, bounds.width - OnyxWorkspaceMetrics.conversationTextInset),
            height: labelHeight
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThinkingAppearance()
    }

    func configure(label value: String) {
        label.stringValue = value
        setAccessibilityValue(value)
        applyThinkingAppearance()
        spinner.startAnimation(nil)
    }

    private func applyThinkingAppearance() {
        // The pending row is the only feedback available while a provider is
        // spending time thinking before it has emitted a visible assistant
        // item. Do not rely on AppKit's secondary-label color here: a native
        // view can be created while its hosting window is still in the default
        // appearance, which briefly resolves that dynamic color to near-black
        // on Onyx's near-black canvas. Resolve an explicit, high-contrast
        // treatment every time the view's effective appearance changes.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = TranscriptPendingResponsePresentation.colors(for: effectiveAppearance)
        let tint = colors.tint
        let text = colors.text
        self.label.textColor = text
        // A restrained tinted wash gives the row a visible boundary without
        // turning routine progress into a bright card. The text itself remains
        // fully opaque so it is readable even if the wash is imperceptible on
        // a particular display or accessibility contrast setting.
        layer?.backgroundColor = tint.withAlphaComponent(isDark ? 0.14 : 0.09).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(isDark ? 0.34 : 0.25).cgColor
    }
}

private final class TranscriptPendingCollectionItem: NSCollectionViewItem {
    override func loadView() {
        view = TranscriptPendingResponseView()
    }

    func configure(label: String) {
        (view as? TranscriptPendingResponseView)?.configure(label: label)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? TranscriptPendingResponseView)?.configure(label: "Working")
    }
}

/// The compact, reversible surface for a contiguous run of routine activity.
/// It intentionally has no provider payload of its own: opening it restores
/// the original child rows, including their individual disclosure controls.
final class TranscriptActivityGroupView: NSView {
    static let rowHeight: CGFloat = 30

    private let titleLabel = NSTextField(labelWithString: "Activity")
    let expansionControl = NSButton(title: "", target: nil, action: nil)
    private var group: TranscriptActivityGroup?
    private var fullTitle = "Activity"
    private var onToggle: ((Bool) -> Void)?
    private(set) var isExpanded = false
    var representedItemIDs: [String] { group?.itemIDs ?? [] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: OnyxTypography.reading, weight: .regular)
        titleLabel.textColor = OnyxTheme.readingNSColor(for: effectiveAppearance)
            .withAlphaComponent(0.86)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true

        expansionControl.isBordered = false
        expansionControl.bezelStyle = .regularSquare
        expansionControl.imagePosition = .imageOnly
        expansionControl.imageScaling = .scaleProportionallyDown
        expansionControl.contentTintColor = .secondaryLabelColor
        expansionControl.focusRingType = .default
        expansionControl.target = self
        expansionControl.action = #selector(disclosurePressed(_:))
        expansionControl.setAccessibilityRole(.button)
        expansionControl.setAccessibilityLabel("Expand activity details")
        expansionControl.setAccessibilityHelp("Shows each routine tool, command, and file change")

        addSubview(titleLabel)
        addSubview(expansionControl)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Keep the compact group title on the explicit low-glare ramp. As
        // with cell headers, alpha-applied dynamic label colors can resolve
        // to pure white when copied into an attributed string.
        titleLabel.textColor = OnyxTheme.readingNSColor(for: effectiveAppearance)
            .withAlphaComponent(0.86)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        group: TranscriptActivityGroup,
        isExpanded: Bool,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        self.group = group
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        fullTitle = "\(group.title)  ·  \(group.summary)"
        titleLabel.stringValue = fullTitle
        TranscriptDisclosurePresentation.apply(
            to: expansionControl,
            isExpanded: isExpanded,
            tint: .tertiaryLabelColor
        )
        expansionControl.setAccessibilityLabel(
            "\(isExpanded ? "Collapse" : "Expand") \(group.title)"
        )
        expansionControl.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        setAccessibilityLabel(group.title)
        setAccessibilityValue(
            "Completed, \(group.summary), \(isExpanded ? "Expanded" : "Collapsed")"
        )
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        group = nil
        fullTitle = "Activity"
        onToggle = nil
        isExpanded = false
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            toggleExpansion()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        toggleExpansion()
        return true
    }

    @objc private func disclosurePressed(_ sender: NSButton) {
        toggleExpansion()
    }

    private func toggleExpansion() {
        guard group != nil else { return }
        isExpanded.toggle()
        TranscriptDisclosurePresentation.apply(
            to: expansionControl,
            isExpanded: isExpanded,
            tint: .tertiaryLabelColor
        )
        expansionControl.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        if let group {
            setAccessibilityValue(
                "Completed, \(group.summary), \(isExpanded ? "Expanded" : "Collapsed")"
            )
        }
        onToggle?(isExpanded)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return expansionControl.frame.contains(point) ? expansionControl : self
    }

    override func mouseDown(with event: NSEvent) {
        // `hitTest` routes the quiet row body here while preserving the native
        // button for the disclosure glyph itself. This makes the advertised
        // whole-row target real rather than forwarding an out-of-bounds click
        // to a 22-point button that AppKit will decline.
        toggleExpansion()
    }

    override func layout() {
        super.layout()
        // Keep disclosure next to the readable content. A detached control at
        // the far edge of every row forms a second, noisy visual column.
        let textX = OnyxWorkspaceMetrics.conversationTextInset
        let disclosureWidth = textX
        titleLabel.frame = NSRect(
            x: textX,
            y: bounds.midY - 9,
            width: max(0, bounds.width - textX - 8),
            height: 18
        )
        titleLabel.attributedStringValue = TranscriptCellView.tailTruncatedSingleLine(
            NSAttributedString(
                string: fullTitle,
                attributes: [
                    .font: titleLabel.font ?? NSFont.systemFont(ofSize: OnyxTypography.reading),
                    .foregroundColor: titleLabel.textColor ?? NSColor.secondaryLabelColor,
                ]
            ),
            width: titleLabel.bounds.width
        )
        expansionControl.frame = NSRect(
            x: 0,
            y: 0,
            width: disclosureWidth,
            height: bounds.height
        )
    }
}

private enum TranscriptDisclosurePresentation {
    @MainActor
    static func apply(
        to button: NSButton,
        isExpanded: Bool,
        tint: NSColor
    ) {
        let symbolName = isExpanded ? "chevron.down" : "chevron.right"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = isExpanded ? "⌄" : "›"
        }
        button.contentTintColor = tint
    }
}

final class TranscriptActivityGroupCollectionItem: NSCollectionViewItem {
    override func loadView() {
        view = TranscriptActivityGroupView()
    }

    func configure(
        group: TranscriptActivityGroup,
        isExpanded: Bool,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        (view as? TranscriptActivityGroupView)?.configure(
            group: group,
            isExpanded: isExpanded,
            onToggle: onToggle
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? TranscriptActivityGroupView)?.prepareForReuse()
    }
}

private final class TranscriptCollectionItem: NSCollectionViewItem {
    override func loadView() {
        view = TranscriptCellView()
    }

    func configure(
        with item: TimelineItem,
        isExpanded: Bool = true,
        isEditable: Bool = false,
        isRetryable: Bool = false,
        onEdit: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        (view as? TranscriptCellView)?.configure(
            with: item,
            isExpanded: isExpanded,
            isEditable: isEditable,
            isRetryable: isRetryable,
            onEdit: onEdit,
            onRetry: onRetry,
            onToggle: onToggle
        )
    }

    func updateEditAction(
        editableUserMessageID: String?,
        retryableFailedResponseItemID: String?,
        onEdit: @escaping (String) -> Void,
        onRetry: @escaping (String) -> Void
    ) {
        guard let cell = view as? TranscriptCellView else { return }
        cell.updateEditAction(
            isEditable: cell.itemID == editableUserMessageID,
            isRetryable: cell.itemID == retryableFailedResponseItemID,
            onEdit: cell.itemID.map { messageID in
                { onEdit(messageID) }
            },
            onRetry: cell.itemID.map { messageID in
                { onRetry(messageID) }
            }
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? TranscriptCellView)?.prepareForReuse()
    }
}

/// Turns the Markdown commonly emitted by coding agents into a lightweight
/// AppKit attributed string. The transcript keeps its recycled native text
/// fields; Foundation does the inline parsing while this small adapter restores
/// block line breaks and readable list/heading prefixes that `NSTextField`
/// otherwise does not infer from presentation-intent attributes.
@MainActor
enum TranscriptMarkdownRenderer {
    static let maximumMarkdownUTF8Bytes = 128 * 1_024
    static let maximumMarkdownLines = 2_048
    static let readingLineSpacing: CGFloat = 2

    private enum BlockStyle {
        case body
        case list
        case heading(Int)
        case quote
        case code
        case thematicBreak
    }

    private struct BlockLine {
        let prefix: String
        let content: String
        let style: BlockStyle
        /// UTF-16 offset of `content` in the original clean Markdown line.
        let contentUTF16Offset: Int
    }

    private struct SourceLine {
        let text: String
        let range: NSRange
    }

    private struct SemanticSlice {
        let role: TranscriptSemanticRole
        let range: NSRange
    }

    private struct SemanticSentinelPair {
        let role: TranscriptSemanticRole
        let start: String
        let end: String
    }

    static func attributedString(
        markdown source: String,
        baseFont: NSFont,
        textColor: NSColor? = nil,
        semanticProjection: TranscriptSemanticMarkupProjection? = nil,
        appearance: NSAppearance? = nil
    ) -> NSAttributedString {
        let textColor = textColor ?? OnyxTheme.readingNSColor(for: nil)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = readingLineSpacing
        let plainAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        guard !source.isEmpty else { return NSAttributedString(string: "", attributes: plainAttributes) }

        // Tool output can be arbitrarily large. Above this limit, preserving
        // the complete selectable text matters more than parsing decoration on
        // the main thread.
        let byteCount = source.utf8.count
        guard byteCount <= maximumMarkdownUTF8Bytes,
              hasBoundedLineCount(source) else {
            return NSAttributedString(string: source, attributes: plainAttributes)
        }

        // A projection is valid only for the exact raw body passed by the
        // caller. This prevents stale streaming projections from coloring a
        // newer cumulative body. The durable source itself remains untouched.
        let semanticProjection = semanticProjection?.rawText == source
            ? semanticProjection
            : nil
        let renderSource = semanticProjection?.cleanText ?? source

        var renderedLines: [NSAttributedString] = []
        renderedLines.reserveCapacity(min(256, max(1, byteCount / 48)))
        var fence: String?

        for line in sourceLines(renderSource) {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let delimiter = fence {
                if trimmed.hasPrefix(delimiter) {
                    fence = nil
                } else {
                    // Parser-protected fenced code never produces semantic
                    // regions, so code remains exact evidence-like prose.
                    renderedLines.append(
                        styledLine(
                            BlockLine(
                                prefix: "",
                                content: line.text,
                                style: .code,
                                contentUTF16Offset: 0
                            ),
                            baseFont: baseFont,
                            textColor: textColor,
                            semanticSlices: [],
                            appearance: appearance
                        )
                    )
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            let block = parseBlock(line.text)
            renderedLines.append(
                styledLine(
                    block,
                    baseFont: baseFont,
                    textColor: textColor,
                    semanticSlices: semanticSlices(
                        for: block,
                        lineRange: line.range,
                        regions: semanticProjection?.regions ?? []
                    ),
                    appearance: appearance
                )
            )
        }

        let result = NSMutableAttributedString()
        for (index, line) in renderedLines.enumerated() {
            result.append(line)
            guard index < renderedLines.count - 1 else { continue }
            var newlineAttributes = plainAttributes
            if line.length > 0,
               let lineParagraphStyle = line.attribute(
                   .paragraphStyle,
                   at: line.length - 1,
                   effectiveRange: nil
               ) as? NSParagraphStyle {
                // The paragraph separator participates in AppKit's paragraph
                // geometry. Carry the block's own style onto it so a later
                // line cannot flatten a list's hanging indent.
                newlineAttributes[.paragraphStyle] = lineParagraphStyle
            }
            result.append(NSAttributedString(string: "\n", attributes: newlineAttributes))
        }
        return result
    }

    private static func hasBoundedLineCount(_ source: String) -> Bool {
        var lineBreakCount = 0
        for scalar in source.unicodeScalars where CharacterSet.newlines.contains(scalar) {
            lineBreakCount += 1
            if lineBreakCount >= maximumMarkdownLines { return false }
        }
        return true
    }

    private static func sourceLines(_ source: String) -> [SourceLine] {
        let sourceNSString = source as NSString
        guard sourceNSString.length > 0 else {
            return [SourceLine(text: "", range: NSRange(location: 0, length: 0))]
        }

        var lines: [SourceLine] = []
        var location = 0
        while location < sourceNSString.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            sourceNSString.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
            lines.append(SourceLine(text: sourceNSString.substring(with: range), range: range))
            location = max(lineEnd, location + 1)
        }

        // `components(separatedBy: .newlines)`, used by the original renderer,
        // retains the final empty paragraph. Preserve that selection/copy
        // behavior when the clean Markdown ends in a newline.
        if let finalScalar = source.unicodeScalars.last,
           CharacterSet.newlines.contains(finalScalar) {
            lines.append(
                SourceLine(
                    text: "",
                    range: NSRange(location: sourceNSString.length, length: 0)
                )
            )
        }
        return lines
    }

    /// Produces a marker-free preview without scanning or parsing the complete
    /// activity payload. Invalid Markdown simply remains readable plain text.
    static func compactPlainText(from source: Substring) -> String {
        let cleanSource = TranscriptSemanticMarkup.cleanText(from: String(source))
        let trimmed = cleanSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("```"),
              !trimmed.hasPrefix("~~~") else { return "" }
        let block = parseBlock(trimmed)
        guard case .thematicBreak = block.style else {
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let plain = (try? AttributedString(markdown: block.content, options: options))
                .map { String($0.characters) }
                ?? block.content
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func parseBlock(_ line: String) -> BlockLine {
        let leadingCount = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let leading = String(line.prefix(leadingCount))
        var content = String(line.dropFirst(leadingCount))
        var contentUTF16Offset = leading.utf16.count

        let hashes = content.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), content.dropFirst(hashes).first?.isWhitespace == true {
            let contentAfterHashes = String(content.dropFirst(hashes))
            let whitespaceCount = contentAfterHashes
                .prefix(while: { $0 == " " || $0 == "\t" })
                .utf16.count
            return BlockLine(
                prefix: "",
                content: contentAfterHashes.trimmingCharacters(in: .whitespaces),
                style: .heading(hashes),
                contentUTF16Offset: contentUTF16Offset + hashes + whitespaceCount
            )
        }

        if content.hasPrefix(">") {
            content.removeFirst()
            contentUTF16Offset += 1
            if content.first == " " {
                content.removeFirst()
                contentUTF16Offset += 1
            }
            return BlockLine(
                prefix: "│ ",
                content: content,
                style: .quote,
                contentUTF16Offset: contentUTF16Offset
            )
        }

        if content == "---" || content == "***" || content == "___" {
            return BlockLine(
                prefix: "",
                content: "────────────────",
                style: .thematicBreak,
                contentUTF16Offset: contentUTF16Offset
            )
        }

        var listPrefix: String?
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            content.removeFirst(2)
            contentUTF16Offset += 2
            listPrefix = "• "
        } else {
            let digits = content.prefix(while: { $0.isNumber })
            let remainder = content.dropFirst(digits.count)
            if !digits.isEmpty,
               (remainder.hasPrefix(". ") || remainder.hasPrefix(") ")) {
                content = String(remainder.dropFirst(2))
                contentUTF16Offset += digits.utf16.count + 2
                listPrefix = "\(digits). "
            }
        }

        if let listPrefix {
            var marker = listPrefix
            if content.hasPrefix("[ ] ") {
                content.removeFirst(4)
                contentUTF16Offset += 4
                marker = "☐ "
            } else if content.lowercased().hasPrefix("[x] ") {
                content.removeFirst(4)
                contentUTF16Offset += 4
                marker = "☑ "
            }
            let indentation = String(repeating: "  ", count: min(4, leadingCount / 2))
            return BlockLine(
                prefix: indentation + marker,
                content: content,
                style: .list,
                contentUTF16Offset: contentUTF16Offset
            )
        }

        return BlockLine(
            prefix: leading,
            content: content,
            style: .body,
            contentUTF16Offset: contentUTF16Offset
        )
    }

    private static func styledLine(
        _ block: BlockLine,
        baseFont: NSFont,
        textColor: NSColor,
        semanticSlices: [SemanticSlice],
        appearance: NSAppearance?
    ) -> NSAttributedString {
        let font: NSFont
        let color: NSColor
        switch block.style {
        case .body, .list:
            font = baseFont
            color = textColor
        case let .heading(level):
            let sizes: [CGFloat] = [19, 17.5, 16.5, 15.5, 15, 15]
            font = .systemFont(ofSize: sizes[level - 1], weight: .semibold)
            color = textColor
        case .quote:
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            // Keep quoted prose on the same warm, appearance-aware reading
            // ramp as the surrounding message. Applying alpha to AppKit's
            // dynamic label colors can otherwise resolve back to white.
            color = textColor.withAlphaComponent(0.78)
        case .code:
            font = .monospacedSystemFont(
                ofSize: max(OnyxTypography.reading, baseFont.pointSize - 1),
                weight: .regular
            )
            color = textColor
        case .thematicBreak:
            font = baseFont
            color = .separatorColor
        }

        let line = NSMutableAttributedString(
            string: block.prefix,
            attributes: [.font: font, .foregroundColor: color]
        )
        line.append(
            inlineMarkdown(
                block.content,
                font: font,
                textColor: color,
                semanticSlices: semanticSlices,
                appearance: appearance
            )
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = readingLineSpacing
        if case .list = block.style {
            // The marker is real selectable text. Subsequent visual lines need
            // to begin after that marker, not underneath it.
            paragraphStyle.headIndent = ceil(
                (block.prefix as NSString).size(withAttributes: [.font: font]).width
            )
            paragraphStyle.firstLineHeadIndent = 0
        }
        if line.length > 0 {
            line.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: line.length)
            )
        }
        if case .code = block.style, line.length > 0 {
            line.addAttribute(
                .backgroundColor,
                value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                range: NSRange(location: 0, length: line.length)
            )
        }
        return line
    }

    private static func semanticSlices(
        for block: BlockLine,
        lineRange: NSRange,
        regions: [TranscriptSemanticRegion]
    ) -> [SemanticSlice] {
        guard !regions.isEmpty, !block.content.isEmpty else { return [] }
        let contentRange = NSRange(
            location: lineRange.location + block.contentUTF16Offset,
            length: block.content.utf16.count
        )
        guard contentRange.length > 0 else { return [] }

        return regions.compactMap { region in
            let intersection = NSIntersectionRange(contentRange, region.range)
            guard intersection.length > 0 else { return nil }
            return SemanticSlice(
                role: region.role,
                range: NSRange(
                    location: intersection.location - contentRange.location,
                    length: intersection.length
                )
            )
        }
    }

    private static func inlineMarkdown(
        _ source: String,
        font: NSFont,
        textColor: NSColor,
        semanticSlices: [SemanticSlice] = [],
        appearance: NSAppearance? = nil
    ) -> NSAttributedString {
        guard !semanticSlices.isEmpty else {
            return parsedInlineMarkdown(source, font: font, textColor: textColor)
        }

        // Parse the complete clean line with private-use sentinels around each
        // semantic slice. This keeps Markdown delimiters outside a wrapper
        // (for example, `**[onyx:success]Built[/onyx]**`) intact, while the
        // sentinels give us a stable output range after Markdown removes its
        // own syntax. They are deleted before the attributed string is shown.
        let pairs = semanticSlices.enumerated().map { index, slice in
            SemanticSentinelPair(
                role: slice.role,
                start: String(UnicodeScalar(0xE000 + (index * 2))!),
                end: String(UnicodeScalar(0xE001 + (index * 2))!)
            )
        }
        let annotatedSource = NSMutableString(string: source)
        for (slice, pair) in zip(semanticSlices.reversed(), pairs.reversed()) {
            guard slice.range.location >= 0,
                  NSMaxRange(slice.range) <= annotatedSource.length else { continue }
            annotatedSource.insert(pair.end, at: NSMaxRange(slice.range))
            annotatedSource.insert(pair.start, at: slice.range.location)
        }

        let rendered = NSMutableAttributedString(
            attributedString: parsedInlineMarkdown(
                annotatedSource as String,
                font: font,
                textColor: textColor
            )
        )
        let renderedString = rendered.string as NSString
        var sentinelRanges: [NSRange] = []
        sentinelRanges.reserveCapacity(pairs.count * 2)

        for pair in pairs {
            let startRange = renderedString.range(of: pair.start)
            let endRange = renderedString.range(of: pair.end)
            guard startRange.location != NSNotFound,
                  endRange.location != NSNotFound,
                  NSMaxRange(startRange) <= endRange.location else {
                // A future Markdown parser could discard private-use scalars.
                // Keep the older segmented behavior as a safe presentation
                // fallback rather than silently losing semantic color.
                return segmentedInlineMarkdown(
                    source,
                    font: font,
                    textColor: textColor,
                    semanticSlices: semanticSlices,
                    appearance: appearance
                )
            }
            let contentRange = NSRange(
                location: NSMaxRange(startRange),
                length: endRange.location - NSMaxRange(startRange)
            )
            if contentRange.length > 0 {
                rendered.addAttributes(
                    [
                        .foregroundColor: semanticColor(
                            for: pair.role,
                            appearance: appearance
                        ),
                        .onyxSemanticRole: pair.role.rawValue,
                    ],
                    range: contentRange
                )
            }
            sentinelRanges.append(startRange)
            sentinelRanges.append(endRange)
        }

        for range in sentinelRanges.sorted(by: { $0.location > $1.location }) {
            rendered.deleteCharacters(in: range)
        }
        return rendered
    }

    private static func segmentedInlineMarkdown(
        _ source: String,
        font: NSFont,
        textColor: NSColor,
        semanticSlices: [SemanticSlice],
        appearance: NSAppearance?
    ) -> NSAttributedString {
        let sourceNSString = source as NSString
        let result = NSMutableAttributedString()
        var cursor = 0
        for slice in semanticSlices {
            guard slice.range.location >= cursor,
                  NSMaxRange(slice.range) <= sourceNSString.length else { continue }
            if slice.range.location > cursor {
                let prefix = sourceNSString.substring(
                    with: NSRange(location: cursor, length: slice.range.location - cursor)
                )
                result.append(parsedInlineMarkdown(prefix, font: font, textColor: textColor))
            }

            let semanticSource = sourceNSString.substring(with: slice.range)
            let renderedSemantic = NSMutableAttributedString(
                attributedString: parsedInlineMarkdown(
                    semanticSource,
                    font: font,
                    textColor: textColor
                )
            )
            if renderedSemantic.length > 0 {
                renderedSemantic.addAttributes(
                    [
                        .foregroundColor: semanticColor(
                            for: slice.role,
                            appearance: appearance
                        ),
                        .onyxSemanticRole: slice.role.rawValue,
                    ],
                    range: NSRange(location: 0, length: renderedSemantic.length)
                )
            }
            result.append(renderedSemantic)
            cursor = NSMaxRange(slice.range)
        }
        if cursor < sourceNSString.length {
            result.append(
                parsedInlineMarkdown(
                    sourceNSString.substring(
                        with: NSRange(
                            location: cursor,
                            length: sourceNSString.length - cursor
                        )
                    ),
                    font: font,
                    textColor: textColor
                )
            )
        }
        return result
    }

    private static func parsedInlineMarkdown(
        _ source: String,
        font: NSFont,
        textColor: NSColor
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: textColor])
        }

        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([.font: font, .foregroundColor: textColor], range: fullRange)
        let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        result.enumerateAttribute(inlineIntentKey, in: fullRange) { value, range, _ in
            guard let rawValue = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: rawValue)
            var renderedFont = font
            if intent.contains(.code) {
                renderedFont = .monospacedSystemFont(
                    ofSize: max(OnyxTypography.reading, font.pointSize - 0.5),
                    weight: .regular
                )
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                    range: range
                )
            } else {
                if intent.contains(.stronglyEmphasized) {
                    renderedFont = .systemFont(ofSize: font.pointSize, weight: .semibold)
                }
                var traits: NSFontTraitMask = []
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    renderedFont = NSFontManager.shared.convert(renderedFont, toHaveTrait: traits)
                }
            }
            result.addAttribute(.font, value: renderedFont, range: range)
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        result.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let url = validatedWebURL(from: value) else {
                result.removeAttribute(.link, range: range)
                return
            }
            result.addAttributes(
                [
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
        }
        return result
    }

    private static func semanticColor(
        for role: TranscriptSemanticRole,
        appearance: NSAppearance?
    ) -> NSColor {
        switch role {
        case .intent: OnyxTheme.irisNSColor(for: appearance)
        case .working: OnyxTheme.electricNSColor(for: appearance)
        case .success: OnyxTheme.successNSColor(for: appearance)
        case .attention: OnyxTheme.warningNSColor(for: appearance)
        case .failure: OnyxTheme.destructiveNSColor(for: appearance)
        }
    }

    private static func validatedWebURL(from value: Any?) -> URL? {
        let url: URL?
        if let value = value as? URL {
            url = value
        } else if let value = value as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

final class TranscriptEditControl: NSButton {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

final class TranscriptCellView: NSView {
    static let maximumVisibleAttachments = TranscriptLayoutState.maximumVisibleAttachments
    static let maximumVisibleLinks = TranscriptLayoutState.maximumVisibleLinks
    private static let messageFontSize = OnyxTypography.reading
    private static let userBubbleHorizontalPadding: CGFloat = 14
    /// `NSTextFieldCell` wraps a line that only barely clears the raw glyph
    /// measurement. Keep a small fit allowance inside compact user bubbles so
    /// display rounding cannot turn a one-line message into clipped two-line
    /// text.
    private static let userBubbleTextFitAllowance: CGFloat = 6
    /// Activity can use the available pane width between balanced inner
    /// gutters; assistant prose keeps a generous readable measure below.
    /// The outer flow layout still supplies the pane-wide row and edge gutter.
    private static let conversationTrailingInset = OnyxWorkspaceMetrics.conversationTextInset

    private let bubbleBackground = NSView()
    private let avatar = NSTextField(labelWithString: "◆")
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// Visually tiny, interactively generous. The pencil appears only while
    /// the latest eligible user row is hovered or keyboard-focused, while the
    /// native button remains exposed to assistive technology.
    let editControl = TranscriptEditControl(title: "", target: nil, action: nil)
    /// Failed turns expose a direct recovery action beside Edit. This remains
    /// visually restrained, but unlike the pencil it is labeled and visible
    /// without requiring the user to discover a hover-only target.
    let retryControl = TranscriptEditControl(title: "Retry", target: nil, action: nil)
    /// A small native button whose hit area is expanded to the complete card
    /// header in `hitTest(_:)`. This gives mouse, keyboard, and VoiceOver users
    /// one consistent disclosure control without intercepting body selection or
    /// resource/image links.
    let expansionControl = NSButton(title: "", target: nil, action: nil)
    private var attachmentViews: [TranscriptAttachmentView] = []
    private var linkViews: [TranscriptResourceLinkView] = []
    private var item: TimelineItem?
    private var fullTitleAttributedText = NSAttributedString()
    private var onToggle: ((Bool) -> Void)?
    private var onEdit: (() -> Void)?
    private var onRetry: (() -> Void)?
    private var editTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isEditControlFocused = false
    private var isEditable = false
    private var isRetryable = false
    private(set) var isExpanded = true
    private var isExpandable = false

    var isCollapsed: Bool { isExpandable && !isExpanded }
    var canToggleExpansion: Bool { isExpandable }
    var messageBubbleFrame: NSRect { bubbleBackground.frame }
    var titleFrame: NSRect { titleLabel.frame }
    var bodyFrame: NSRect { bodyLabel.frame }
    var statusFrame: NSRect { statusLabel.frame }
    var itemID: String? { item?.id }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bubbleBackground.wantsLayer = true
        bubbleBackground.layer?.cornerRadius = 12
        bubbleBackground.layer?.borderWidth = 0
        addSubview(bubbleBackground)
        addSubview(avatar)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(bodyLabel)
        addSubview(detailLabel)
        addSubview(statusLabel)
        addSubview(expansionControl)
        addSubview(editControl)
        addSubview(retryControl)

        avatar.font = .systemFont(ofSize: OnyxTypography.secondary, weight: .semibold)
        avatar.textColor = NSColor.systemIndigo
        titleLabel.font = .systemFont(ofSize: OnyxTypography.reading, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        summaryLabel.font = .systemFont(ofSize: OnyxTypography.reading, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.usesSingleLineMode = true
        bodyLabel.font = .systemFont(ofSize: Self.messageFontSize, weight: .regular)
        bodyLabel.textColor = OnyxTheme.readingNSColor(for: effectiveAppearance)
        bodyLabel.isSelectable = true
        bodyLabel.allowsEditingTextAttributes = true
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        detailLabel.font = .systemFont(ofSize: OnyxTypography.secondary, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: OnyxTypography.metadata, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.wantsLayer = true
        statusLabel.layer?.masksToBounds = false

        expansionControl.isBordered = false
        expansionControl.bezelStyle = .regularSquare
        expansionControl.imagePosition = .imageOnly
        expansionControl.imageScaling = .scaleProportionallyDown
        expansionControl.contentTintColor = .secondaryLabelColor
        expansionControl.focusRingType = .default
        expansionControl.target = self
        expansionControl.action = #selector(disclosurePressed(_:))
        expansionControl.setAccessibilityRole(.button)
        expansionControl.setAccessibilityLabel("Expand activity details")
        expansionControl.setAccessibilityHelp("Shows the complete tool output, attachments, and links")

        editControl.isBordered = false
        editControl.bezelStyle = .regularSquare
        editControl.imagePosition = .imageOnly
        editControl.imageScaling = .scaleProportionallyDown
        editControl.image = NSImage(
            systemSymbolName: "pencil",
            accessibilityDescription: "Edit last message"
        )
        editControl.contentTintColor = .secondaryLabelColor
        editControl.focusRingType = .default
        editControl.target = self
        editControl.action = #selector(editPressed(_:))
        editControl.toolTip = "Edit last message"
        editControl.setAccessibilityRole(.button)
        editControl.setAccessibilityLabel("Edit last message")
        editControl.setAccessibilityHelp(
            "Moves the latest message back to the composer so it can be corrected and resent"
        )
        editControl.onFocusChange = { [weak self] focused in
            self?.isEditControlFocused = focused
            self?.updateEditControlVisibility()
        }
        editControl.isHidden = true

        retryControl.isBordered = false
        retryControl.bezelStyle = .regularSquare
        retryControl.imagePosition = .imageLeading
        retryControl.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Retry failed response"
        )
        retryControl.font = .systemFont(ofSize: OnyxTypography.metadata, weight: .medium)
        retryControl.contentTintColor = .secondaryLabelColor
        retryControl.focusRingType = .default
        retryControl.target = self
        retryControl.action = #selector(retryPressed(_:))
        retryControl.toolTip = "Retry failed response"
        retryControl.setAccessibilityRole(.button)
        retryControl.setAccessibilityLabel("Retry failed response")
        retryControl.setAccessibilityHelp(
            "Removes the failed response and sends this message again"
        )
        retryControl.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // `NSTextField` stores the concrete colors inside its attributed value.
        // Re-render the mounted item when the hosting appearance changes so
        // light-mode text cannot linger after a dark-mode transition (or vice
        // versa) in a recycled transcript row.
        applyItemAppearance()
    }

    /// Compatibility entry point for callers/tests that do not provide a
    /// persisted expansion value. This preserves the original standalone-cell
    /// behavior; the live collection controller supplies the persisted value
    /// explicitly and starts collapsible activity rows compact.
    func configure(with item: TimelineItem) {
        configure(with: item, isExpanded: true)
    }

    func configure(
        with item: TimelineItem,
        isExpanded: Bool,
        isEditable: Bool = false,
        isRetryable: Bool = false,
        onEdit: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        removeMediaViews()
        self.item = item
        self.isExpandable = item.kind.isCollapsibleActivity
        self.isExpanded = self.isExpandable ? isExpanded : true
        self.onToggle = onToggle
        self.onEdit = onEdit
        self.onRetry = onRetry

        fullTitleAttributedText = Self.headerAttributedText(
            for: item,
            isExpanded: self.isExpanded,
            appearance: effectiveAppearance
        )
        titleLabel.attributedStringValue = fullTitleAttributedText
        summaryLabel.stringValue = Self.compactSummary(for: item)
        bodyLabel.font = Self.bodyFont(for: item)
        // A collapsed activity may hide megabytes of provider output. Do not
        // duplicate and parse that payload into an attributed string until the
        // user actually opens the row.
        bodyLabel.attributedStringValue = self.isExpanded
            ? Self.bodyAttributedText(for: item, appearance: effectiveAppearance)
            : NSAttributedString()
        detailLabel.stringValue = detailText(for: item, collapsed: self.isExpandable && !self.isExpanded)
        statusLabel.stringValue = statusText(for: item.status)
        avatar.stringValue = avatarGlyph(for: item.kind)
        avatar.textColor = activityIconColor(for: item.kind, status: item.status)
        detailLabel.textColor = item.kind.isRoutineActivity
            ? .tertiaryLabelColor
            : .secondaryLabelColor
        statusLabel.textColor = statusTextColor(for: item.status)

        let isProminentActivity = item.isProminentActivity
        let isExpandedRoutineActivity = item.kind.isRoutineActivity && self.isExpanded
        layer?.cornerRadius = isProminentActivity ? 10 : (isExpandedRoutineActivity ? 8 : 0)
        layer?.borderWidth = isProminentActivity ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        layer?.backgroundColor = if isProminentActivity {
            backgroundColor(for: item.kind).cgColor
        } else if isExpandedRoutineActivity {
            NSColor.controlBackgroundColor.withAlphaComponent(0.18).cgColor
        } else {
            NSColor.clear.cgColor
        }
        bubbleBackground.isHidden = item.kind != .userMessage
        bubbleBackground.layer?.backgroundColor = backgroundColor(for: item.kind).cgColor
        // Status copy is deliberately plain text. A filled red capsule at the
        // far edge of a failed row reads like debug UI and competes with the
        // useful error itself; the leading disclosure/icon carries the small
        // semantic color accent instead.
        statusLabel.layer?.backgroundColor = NSColor.clear.cgColor

        if self.isExpanded {
            rebuildMediaViews()
        }
        applyExpansionPresentation()
        updateEditAction(
            isEditable: isEditable,
            isRetryable: isRetryable,
            onEdit: onEdit,
            onRetry: onRetry
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        removeMediaViews()
        onToggle = nil
        onEdit = nil
        onRetry = nil
        item = nil
        fullTitleAttributedText = NSAttributedString()
        isExpandable = false
        isExpanded = true
        isEditable = false
        isRetryable = false
        isPointerInside = false
        isEditControlFocused = false
        updateEditControlVisibility()
        setAccessibilityElement(false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if isExpandable, event.keyCode == 36 || event.keyCode == 49 {
            toggleExpansion()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isExpandable else { return false }
        toggleExpansion()
        return true
    }

    @objc private func disclosurePressed(_ sender: NSButton) {
        toggleExpansion()
    }

    @objc private func editPressed(_ sender: NSButton) {
        guard isEditable else { return }
        onEdit?()
    }

    @objc private func retryPressed(_ sender: NSButton) {
        guard isRetryable else { return }
        onRetry?()
    }

    func updateEditAction(
        isEditable: Bool,
        isRetryable: Bool = false,
        onEdit: (() -> Void)?,
        onRetry: (() -> Void)? = nil
    ) {
        let retryabilityChanged = self.isRetryable != isRetryable
        self.isEditable = isEditable && item?.kind == .userMessage
        self.isRetryable = isRetryable && (item?.kind == .assistantMessage || item?.kind == .error)
        self.onEdit = self.isEditable ? onEdit : nil
        self.onRetry = self.isRetryable ? onRetry : nil
        updateEditControlVisibility()
        updateTrackingAreas()
        if retryabilityChanged {
            needsLayout = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let editTrackingArea {
            removeTrackingArea(editTrackingArea)
            self.editTrackingArea = nil
        }
        guard isEditable else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        editTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateEditControlVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateEditControlVisibility()
    }

    private func updateEditControlVisibility() {
        editControl.isEnabled = isEditable
        editControl.isHidden = !isEditable
        editControl.alphaValue = if !isEditable {
            0
        } else if isPointerInside || isEditControlFocused {
            1
        } else {
            0.55
        }
        retryControl.isEnabled = isRetryable
        retryControl.isHidden = !isRetryable
    }

    func toggleExpansion() {
        guard isExpandable else { return }
        isExpanded.toggle()
        if isExpanded {
            if let item {
                bodyLabel.attributedStringValue = Self.bodyAttributedText(
                    for: item,
                    appearance: effectiveAppearance
                )
            }
            rebuildMediaViews()
        } else {
            bodyLabel.attributedStringValue = NSAttributedString()
            removeMediaViews()
        }
        applyExpansionPresentation()
        onToggle?(isExpanded)
    }

    private func removeMediaViews() {
        attachmentViews.forEach { view in
            view.cancelLoading()
            view.removeFromSuperview()
        }
        attachmentViews.removeAll(keepingCapacity: true)
        linkViews.forEach { $0.removeFromSuperview() }
        linkViews.removeAll(keepingCapacity: true)
    }

    private func rebuildMediaViews() {
        guard let item else { return }
        removeMediaViews()
        attachmentViews = item.attachments.map { attachment in
            let view = TranscriptAttachmentView(attachment: attachment)
            addSubview(view)
            return view
        }
        linkViews = item.links.map { link in
            let view = TranscriptResourceLinkView(link: link)
            addSubview(view)
            return view
        }
    }

    private func applyExpansionPresentation() {
        guard let item else { return }
        let collapsed = isExpandable && !isExpanded
        let isProminentActivity = item.isProminentActivity
        let isExpandedRoutineActivity = item.kind.isRoutineActivity && isExpanded
        layer?.cornerRadius = isProminentActivity ? 10 : (isExpandedRoutineActivity ? 8 : 0)
        layer?.borderWidth = isProminentActivity ? 1 : 0
        layer?.backgroundColor = if isProminentActivity {
            backgroundColor(for: item.kind).cgColor
        } else if isExpandedRoutineActivity {
            NSColor.controlBackgroundColor.withAlphaComponent(0.18).cgColor
        } else {
            NSColor.clear.cgColor
        }
        fullTitleAttributedText = Self.headerAttributedText(
            for: item,
            isExpanded: isExpanded,
            appearance: effectiveAppearance
        )
        titleLabel.attributedStringValue = fullTitleAttributedText
        summaryLabel.isHidden = !collapsed || item.body.isEmpty
        bodyLabel.isHidden = collapsed || item.body.isEmpty
        detailLabel.stringValue = detailText(for: item, collapsed: collapsed)
        expansionControl.isHidden = !isExpandable
        TranscriptDisclosurePresentation.apply(
            to: expansionControl,
            isExpanded: isExpanded,
            tint: disclosureTintColor(for: item.status)
        )
        expansionControl.setAccessibilityLabel(
            "\(isExpanded ? "Collapse" : "Expand") \(displayTitle(for: item)) details"
        )
        expansionControl.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        expansionControl.setAccessibilityHelp(
            isExpanded
                ? "Hides verbose activity output"
                : "Shows the complete tool output, attachments, and links"
        )
        applyActivityAccessibilityPresentation(for: item)
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isExpandable, let item else { return super.hitTest(point) }
        let metrics = Self.metrics(
            for: item,
            width: bounds.width,
            isExpanded: isExpanded,
            isRetryable: isRetryable
        )
        let bodyTop = bounds.height - metrics.top - metrics.titleHeight - metrics.titleGap
        let headerBottom = isExpanded
            ? bodyTop
            : bodyTop - metrics.summaryHeight
        let headerRect = NSRect(
            x: 0,
            y: headerBottom,
            width: bounds.width,
            height: bounds.height - headerBottom
        )
        if headerRect.contains(point) {
            return expansionControl.frame.contains(point) ? expansionControl : self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isExpandable, let item else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let metrics = Self.metrics(
            for: item,
            width: bounds.width,
            isExpanded: isExpanded,
            isRetryable: isRetryable
        )
        let bodyTop = bounds.height - metrics.top - metrics.titleHeight - metrics.titleGap
        let headerBottom = isExpanded ? bodyTop : bodyTop - metrics.summaryHeight
        let headerRect = NSRect(
            x: 0,
            y: headerBottom,
            width: bounds.width,
            height: bounds.height - headerBottom
        )
        guard headerRect.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        toggleExpansion()
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let metrics = Self.metrics(
            for: item,
            width: bounds.width,
            isExpanded: isExpanded,
            isRetryable: isRetryable
        )
        if item.kind == .userMessage {
            let horizontalInset = Self.userBubbleHorizontalPadding
            bubbleBackground.frame = NSRect(
                x: max(0, metrics.contentX - horizontalInset),
                y: 0,
                width: min(bounds.width, metrics.contentWidth + horizontalInset * 2),
                height: bounds.height
            )
        } else {
            bubbleBackground.frame = .zero
        }
        let editTargetSize = OnyxHitTarget.compact
        editControl.frame = NSRect(
            x: max(0, bubbleBackground.frame.minX - editTargetSize - 4),
            y: max(0, min(bounds.height - editTargetSize, 2)),
            width: editTargetSize,
            height: editTargetSize
        )
        retryControl.frame = NSRect(
            x: max(0, metrics.contentX + metrics.contentWidth - 66),
            y: max(0, bounds.height - editTargetSize),
            width: 66,
            height: editTargetSize
        )
        let headerTop = bounds.height - metrics.top
        let disclosureWidth: CGFloat = isExpandable ? 18 : 0
        avatar.frame = NSRect(
            x: metrics.avatarX,
            y: headerTop - 20,
            width: 20,
            height: 18
        )
        titleLabel.frame = NSRect(
            x: metrics.contentX,
            y: headerTop - metrics.titleHeight,
            width: max(
                0,
                metrics.contentWidth - metrics.statusWidth - 8
                    - (isRetryable ? retryControl.frame.width + 8 : 0)
            ),
            height: metrics.titleHeight
        )
        titleLabel.attributedStringValue = Self.tailTruncatedSingleLine(
            fullTitleAttributedText,
            width: titleLabel.bounds.width
        )
        // Preserve the status semantics in the backing label for UI tests and
        // assistive fallbacks, but never leave a zero-width label visible.
        statusLabel.frame = NSRect(
            x: metrics.contentX + max(0, metrics.contentWidth - metrics.statusWidth),
            y: headerTop - metrics.titleHeight + 1,
            width: metrics.statusWidth,
            height: min(16, metrics.titleHeight)
        )
        if isRetryable {
            retryControl.frame.origin.y = max(
                0,
                headerTop - retryControl.frame.height + 6
            )
        }
        let bodyTop = bounds.height - metrics.top - metrics.titleHeight - metrics.titleGap
        summaryLabel.frame = NSRect(
            x: metrics.contentX,
            y: bodyTop - metrics.summaryHeight,
            width: metrics.contentWidth,
            height: metrics.summaryHeight
        )
        bodyLabel.frame = NSRect(
            x: metrics.contentX,
            y: bodyTop - metrics.bodyHeight,
            width: max(
                0,
                metrics.contentWidth - (isRetryable ? retryControl.frame.width + 8 : 0)
            ),
            height: metrics.bodyHeight
        )
        let attachmentTop = bodyTop - metrics.bodyHeight - metrics.attachmentGap
        for (index, attachmentView) in attachmentViews.enumerated() {
            let column = index % metrics.attachmentColumns
            let row = index / metrics.attachmentColumns
            attachmentView.frame = NSRect(
                x: metrics.contentX + CGFloat(column) * (metrics.attachmentWidth + Self.attachmentSpacing),
                y: attachmentTop - CGFloat(row + 1) * metrics.attachmentHeight
                    - CGFloat(row) * Self.attachmentSpacing,
                width: metrics.attachmentWidth,
                height: metrics.attachmentHeight
            )
            attachmentView.isHidden = !isExpanded
        }
        let linksTop = attachmentTop - metrics.attachmentsHeight - metrics.linkGap
        for (index, linkView) in linkViews.enumerated() {
            linkView.frame = NSRect(
                x: metrics.contentX,
                y: linksTop - CGFloat(index + 1) * metrics.linkHeight
                    - CGFloat(index) * Self.linkSpacing,
                width: metrics.contentWidth,
                height: metrics.linkHeight
            )
            linkView.isHidden = !isExpanded
        }
        detailLabel.frame = NSRect(
            x: metrics.contentX,
            y: metrics.bottom,
            width: metrics.contentWidth,
            height: metrics.detailHeight
        )
        expansionControl.frame = NSRect(
            x: 0,
            y: max(0, headerTop - max(22, metrics.headerHeight) + 2),
            width: isExpandable ? metrics.contentX : disclosureWidth,
            height: min(bounds.height, max(22, metrics.headerHeight))
        )
        avatar.isHidden = !item.kind.isActivity || isExpandable
        titleLabel.isHidden = metrics.titleHeight == 0
        summaryLabel.isHidden = !metrics.isCollapsed || item.body.isEmpty
        bodyLabel.isHidden = metrics.isCollapsed || item.body.isEmpty
        detailLabel.isHidden = metrics.detailHeight == 0
        statusLabel.isHidden = !item.kind.isActivity
            || metrics.titleHeight == 0
            || metrics.statusWidth == 0
    }

    private func applyActivityAccessibilityPresentation(for item: TimelineItem) {
        guard item.kind.isActivity else {
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
            setAccessibilityValue(nil)
            return
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.displayTitle(for: item))
        var values = [accessibilityStatusText(for: item.status)]
        if isExpandable {
            values.append(isExpanded ? "Expanded" : "Collapsed")
        }
        setAccessibilityValue(values.joined(separator: ", "))
    }

    private func applyItemAppearance() {
        bodyLabel.textColor = OnyxTheme.readingNSColor(for: effectiveAppearance)
        guard let item else { return }
        fullTitleAttributedText = Self.headerAttributedText(
            for: item,
            isExpanded: isExpanded,
            appearance: effectiveAppearance
        )
        titleLabel.attributedStringValue = fullTitleAttributedText
        if isExpanded {
            bodyLabel.attributedStringValue = Self.bodyAttributedText(
                for: item,
                appearance: effectiveAppearance
            )
        }
        avatar.textColor = activityIconColor(for: item.kind, status: item.status)
        statusLabel.textColor = statusTextColor(for: item.status)
        if isExpandable {
            TranscriptDisclosurePresentation.apply(
                to: expansionControl,
                isExpanded: isExpanded,
                tint: disclosureTintColor(for: item.status)
            )
        }
        let isProminentActivity = item.isProminentActivity
        let isExpandedRoutineActivity = item.kind.isRoutineActivity && isExpanded
        layer?.backgroundColor = if isProminentActivity {
            backgroundColor(for: item.kind).cgColor
        } else if isExpandedRoutineActivity {
            NSColor.controlBackgroundColor.withAlphaComponent(0.18).cgColor
        } else {
            NSColor.clear.cgColor
        }
        if item.kind == .userMessage {
            bubbleBackground.layer?.backgroundColor = backgroundColor(for: item.kind).cgColor
        }
        needsDisplay = true
    }

    /// Legacy bounded measurement retained for callers that only need a
    /// conservative estimate. The live collection view uses the explicit
    /// expansion overload below, which renders every attachment/link when
    /// expanded.
    static func height(for item: TimelineItem, width: CGFloat) -> CGFloat {
        height(for: item, width: width, isExpanded: true, boundedMedia: true)
    }

    static func height(for item: TimelineItem, width: CGFloat, isExpanded: Bool) -> CGFloat {
        height(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: false,
            isRetryable: false
        )
    }

    static func height(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        isRetryable: Bool
    ) -> CGFloat {
        height(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: false,
            isRetryable: isRetryable
        )
    }

    private static func height(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        boundedMedia: Bool,
        isRetryable: Bool = false
    ) -> CGFloat {
        let metrics = metrics(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: boundedMedia,
            isRetryable: isRetryable
        )
        return metrics.top + metrics.titleHeight + metrics.titleGap
            + metrics.summaryHeight + metrics.bodyHeight
            + metrics.attachmentGap + metrics.attachmentsHeight
            + metrics.linkGap + metrics.linksHeight
            + metrics.detailGap + metrics.detailHeight + metrics.bottom
    }

    static func metrics(for item: TimelineItem, width: CGFloat) -> Metrics {
        metrics(
            for: item,
            width: width,
            isExpanded: true,
            boundedMedia: true,
            isRetryable: false
        )
    }

    static func metrics(for item: TimelineItem, width: CGFloat, isExpanded: Bool) -> Metrics {
        metrics(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: false,
            isRetryable: false
        )
    }

    static func metrics(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        isRetryable: Bool
    ) -> Metrics {
        metrics(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: false,
            isRetryable: isRetryable
        )
    }

    private static func metrics(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        boundedMedia: Bool,
        isRetryable: Bool
    ) -> Metrics {
        let isUser = item.kind == .userMessage
        let isActivity = item.kind.isActivity
        let isRoutineActivity = item.kind.isRoutineActivity
        let isCollapsed = item.kind.isCollapsibleActivity && !isExpanded
        let isQuietRoutineActivity = isRoutineActivity
            && isCollapsed
        let horizontalInset: CGFloat = isUser ? userBubbleHorizontalPadding : 0
        let userBubbleMaximum = min(560, width * 0.78)
        let preferredUserBubbleWidth = item.attachments.isEmpty && item.links.isEmpty
            ? item.body.preferredBubbleWidth(fontSize: messageFontSize)
                + userBubbleTextFitAllowance
            : max(360, width * 0.56)
        let userBubbleWidth = min(userBubbleMaximum, max(52, preferredUserBubbleWidth))
        let contentX: CGFloat = isUser
            ? max(0, width - userBubbleWidth) + horizontalInset
            : OnyxWorkspaceMetrics.conversationTextInset
        let trailing: CGFloat = isUser
            ? horizontalInset
            : Self.conversationTrailingInset
        let availableContentWidth = max(isUser ? 22 : 100, width - contentX - trailing)
        let contentWidth = item.kind == .assistantMessage
            ? min(OnyxWorkspaceMetrics.maximumConversationTextWidth, availableContentWidth)
            : availableContentWidth
        let title = displayTitle(for: item)
        let titleHeight: CGFloat = title.isEmpty ? 0 : 18
        let detailString = isCollapsed ? "" : visibleDetail(for: item)
        let detailHeight: CGFloat = detailString.isEmpty ? 0 : 16
        let displayed = displayBody(item, isExpanded: isExpanded)
        // Collapsed activity renders its preview in the header (routine) or
        // summary label (other collapsible kinds). Reserving a second hidden
        // body here was the reason compact rows still looked like large cards.
        let bodyMeasurementWidth = max(
            1,
            contentWidth - (isRetryable ? OnyxHitTarget.compact + 42 : 0)
        )
        var bodyHeight = isCollapsed
            ? 0
            : bodyAttributedText(for: item).boundingHeight(width: bodyMeasurementWidth)
        if displayed.isEmpty { bodyHeight = 0 }
        // The legacy bounded estimate protects old callers from an enormous
        // speculative row. The live explicit-expanded path must retain the
        // complete readable output, so it intentionally has no truncation.
        if isActivity, !isCollapsed, boundedMedia { bodyHeight = min(bodyHeight, 188) }
        // Routine collapsed output is folded into the single-line header. It
        // keeps enough context to identify the work without doubling each
        // event's vertical footprint.
        let summaryHeight: CGFloat = isCollapsed && !item.body.isEmpty && !isRoutineActivity ? 17 : 0
        let attachmentCount: Int
        if isCollapsed {
            attachmentCount = 0
        } else if boundedMedia {
            attachmentCount = min(maximumVisibleAttachments, item.attachments.count)
        } else {
            attachmentCount = item.attachments.count
        }
        let attachmentColumns = attachmentCount > 1 ? 2 : 1
        let attachmentWidth = attachmentCount > 1
            ? floor((contentWidth - attachmentSpacing) / 2)
            : min(360, contentWidth)
        let attachmentHeight = attachmentCount > 0
            ? min(220, max(116, floor(attachmentWidth * 0.64)))
            : 0
        let attachmentRows = attachmentCount == 0
            ? 0
            : Int(ceil(Double(attachmentCount) / Double(attachmentColumns)))
        let attachmentsHeight = CGFloat(attachmentRows) * attachmentHeight
            + CGFloat(max(0, attachmentRows - 1)) * attachmentSpacing
        let attachmentGap: CGFloat = attachmentCount > 0 && bodyHeight > 0 ? 9 : 0
        let linkCount: Int
        if isCollapsed {
            linkCount = 0
        } else if boundedMedia {
            linkCount = min(Self.maximumVisibleLinks, item.links.count)
        } else {
            linkCount = item.links.count
        }
        let linkHeight: CGFloat = linkCount > 0 ? 34 : 0
        let linksHeight = CGFloat(linkCount) * linkHeight
            + CGFloat(max(0, linkCount - 1)) * linkSpacing
        let linkGap: CGFloat = linkCount > 0
            && (bodyHeight > 0 || attachmentsHeight > 0) ? 9 : 0
        let contentHeightBeforeDetail = bodyHeight + attachmentGap + attachmentsHeight
            + linkGap + linksHeight
        let titleGap: CGFloat = isCollapsed
            ? (titleHeight > 0 && summaryHeight > 0 ? 3 : 0)
            : (titleHeight > 0 && bodyHeight > 0 ? 5 : 0)
        let top: CGFloat
        let bottom: CGFloat
        if isQuietRoutineActivity && isCollapsed {
            top = 5
            bottom = 5
        } else if isUser {
            top = 10
            bottom = 10
        } else if !isActivity {
            // Assistant prose is the primary surface. Give it a distinct
            // paragraph rhythm so adjacent implementation updates do not read
            // like one continuous event log.
            top = 15
            bottom = 17
        } else {
            top = isActivity ? (isCollapsed ? 10 : 13) : 8
            bottom = isActivity ? (isCollapsed ? 9 : 12) : 10
        }
        // Routine progress is conveyed by the status-tinted leading disclosure
        // and the row's accessibility value. A right-aligned "Running" on each
        // command/tool row creates a competing status column. Non-routine live
        // rows still need their explicit state, as do exceptional outcomes and
        // actionable approvals.
        // A collapsed routine failure already has a red disclosure plus its
        // one-line error summary. Repeating a detached `Failed` label wastes
        // space and makes the row look like a log inspector. Non-routine live
        // states retain a compact textual status where it adds information.
        let showsStatus = !isRoutineActivity
            && item.kind != .plan
            && item.kind != .error
            && item.status != .completed
        let statusWidth: CGFloat = isActivity && titleHeight > 0 && showsStatus ? 48 : 0
        return Metrics(
            avatarX: 0,
            contentX: contentX,
            contentWidth: contentWidth,
            top: top,
            titleHeight: titleHeight,
            titleGap: titleGap,
            summaryHeight: summaryHeight,
            bodyHeight: bodyHeight,
            attachmentGap: attachmentGap,
            attachmentColumns: attachmentColumns,
            attachmentWidth: attachmentWidth,
            attachmentHeight: attachmentHeight,
            attachmentsHeight: attachmentsHeight,
            linkGap: linkGap,
            linkHeight: linkHeight,
            linksHeight: linksHeight,
            detailGap: detailHeight > 0 && (contentHeightBeforeDetail > 0 || isCollapsed) ? 7 : 0,
            detailHeight: detailHeight,
            bottom: bottom,
            headerHeight: titleHeight + titleGap + summaryHeight,
            statusWidth: statusWidth,
            isCollapsed: isCollapsed
        )
    }

    /// A stable, one-line preview keeps a long JSON/tool payload from taking
    /// over the conversation while leaving the original body untouched for an
    /// expanded card.
    static func compactSummary(for item: TimelineItem, maximumCharacters: Int = 180) -> String {
        guard maximumCharacters > 0 else { return "" }
        if item.kind == .plan, let planSummary = compactPlanSummary(from: item.body) {
            guard planSummary.count > maximumCharacters else { return planSummary }
            guard maximumCharacters > 1 else { return String(planSummary.prefix(1)) }
            return String(planSummary.prefix(maximumCharacters - 1)) + "…"
        }
        let preservesLiteralEvidence = !item.kind.rendersMarkdown
        let previewSampleLength = max(256, min(maximumCharacters, 1_024) * 4)
        let previewSample = String(item.body.prefix(previewSampleLength))
        let projectedPreview = item.kind == .assistantMessage
            ? TranscriptSemanticMarkup.cleanText(from: previewSample)
            : previewSample
        if maximumCharacters == 1 {
            let firstLine = projectedPreview
                .split(whereSeparator: { $0.isNewline })
                .map {
                    preservesLiteralEvidence
                        ? $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        : TranscriptMarkdownRenderer.compactPlainText(from: $0)
                }
                .first(where: { !$0.isEmpty }) ?? ""
            return String(firstLine.prefix(1))
        }
        // Do not scan a multi-megabyte tool payload just to find a preview.
        // The first few kilobytes are enough to produce a useful one-line
        // summary and keep streaming updates cheap on the main thread.
        let oneLine = projectedPreview
            .split(whereSeparator: { $0.isNewline })
            .map {
                preservesLiteralEvidence
                    ? $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    : TranscriptMarkdownRenderer.compactPlainText(from: $0)
            }
            .first(where: { !$0.isEmpty }) ?? ""
        guard oneLine.count > maximumCharacters else { return oneLine }
        return String(oneLine.prefix(maximumCharacters - 1)) + "…"
    }

    /// AppKit clips an attributed `NSTextField` at its frame edge on some
    /// hosted-layout paths even when the field requests tail truncation. Put
    /// the ellipsis in the attributed value itself so compact activity rows
    /// retain an unmistakable disclosure cue at every pane width.
    static func tailTruncatedSingleLine(
        _ source: NSAttributedString,
        width rawWidth: CGFloat
    ) -> NSAttributedString {
        let width = rawWidth.isFinite ? max(0, rawWidth - 1) : 0
        guard source.length > 0, width > 0 else { return NSAttributedString() }
        guard source.size().width <= width else {
            let string = source.string
            var characterEnds: [Int] = [0]
            characterEnds.reserveCapacity(string.count + 1)
            var utf16Length = 0
            for character in string {
                utf16Length += String(character).utf16.count
                characterEnds.append(utf16Length)
            }

            let ellipsisAttributes = source.attributes(
                at: max(0, source.length - 1),
                effectiveRange: nil
            )
            let ellipsis = NSAttributedString(string: "…", attributes: ellipsisAttributes)
            guard ellipsis.size().width <= width else { return NSAttributedString() }

            var lowerBound = 0
            var upperBound = max(0, characterEnds.count - 1)
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound + 1) / 2
                let candidate = NSMutableAttributedString(
                    attributedString: source.attributedSubstring(
                        from: NSRange(location: 0, length: characterEnds[midpoint])
                    )
                )
                candidate.append(ellipsis)
                if candidate.size().width <= width {
                    lowerBound = midpoint
                } else {
                    upperBound = midpoint - 1
                }
            }

            let result = NSMutableAttributedString(
                attributedString: source.attributedSubstring(
                    from: NSRange(location: 0, length: characterEnds[lowerBound])
                )
            )
            result.append(ellipsis)
            return result
        }
        return source
    }

    private static func compactPlanSummary(from body: String) -> String? {
        // Plans are provider content too. Inspect a fixed prefix and a bounded
        // number of lines so a malformed giant plan cannot block the main actor
        // merely to produce its collapsed one-line preview.
        let sample = body.prefix(24_000)
        let steps: [(marker: String, text: String)] = sample
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .prefix(256)
            .compactMap { line -> (marker: String, text: String)? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 4, trimmed.first == "[" else { return nil }
                let marker = String(trimmed.prefix(3)).lowercased()
                guard ["[x]", "[~]", "[ ]", "[?]"].contains(marker) else { return nil }
                let text = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                return (marker, text)
            }
        guard !steps.isEmpty else { return nil }
        let completed = steps.filter { $0.marker == "[x]" }.count
        let activeStep = steps.first(where: { $0.marker == "[~]" })
        let pendingStep = steps.first(where: { $0.marker == "[ ]" || $0.marker == "[?]" })
        let current = activeStep ?? pendingStep
        let progress = "\(completed)/\(steps.count) complete"
        guard let current, !current.text.isEmpty else { return progress }
        return "\(progress)  ·  \(current.text)"
    }

    static func bodyAttributedText(
        for item: TimelineItem,
        appearance: NSAppearance? = nil
    ) -> NSAttributedString {
        let font = bodyFont(for: item)
        let textColor = OnyxTheme.readingNSColor(for: appearance)
        guard item.kind.rendersMarkdown else {
            // Commands, diffs, and tool payloads are evidence. Rendering their
            // leading `+`, `-`, `#`, or `---` as Markdown would change what the
            // user sees and copies from the expanded activity row.
            return NSAttributedString(
                string: item.body,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]
            )
        }
        return TranscriptMarkdownRenderer.attributedString(
            markdown: item.body,
            baseFont: font,
            textColor: textColor,
            semanticProjection: item.kind == .assistantMessage
                ? TranscriptSemanticMarkup.project(item.body)
                : nil,
            appearance: appearance
        )
    }

    private static func bodyFont(for item: TimelineItem) -> NSFont {
        item.kind == .command
            ? .monospacedSystemFont(ofSize: OnyxTypography.reading, weight: .regular)
            : .systemFont(ofSize: messageFontSize, weight: .regular)
    }

    private static func displayBody(_ item: TimelineItem, isExpanded: Bool) -> String {
        if !isExpanded, item.kind.isCollapsibleActivity {
            return compactSummary(for: item)
        }
        return item.body
    }

    private func displayTitle(for item: TimelineItem) -> String {
        Self.displayTitle(for: item)
    }

    static func displayTitle(for item: TimelineItem) -> String {
        if let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard item.kind.isActivity else { return "" }
        return switch item.kind {
        case .reasoning: "Reasoning"
        case .command: "Command"
        case .fileChange: "File change"
        case .tool: "Tool call"
        case .plan: "Plan"
        case .approval: "Approval"
        case .error: "Error"
        case .system: "System"
        case .assistantMessage, .userMessage: ""
        }
    }

    /// Collapsed routine events use one readable line: the semantic action
    /// followed by the first useful output. The underlying body stays intact
    /// and is rendered in full when expanded.
    static func headerText(for item: TimelineItem, isExpanded: Bool) -> String {
        let title = displayTitle(for: item)
        guard item.kind.isRoutineActivity, !isExpanded else { return title }
        let summary = compactSummary(for: item, maximumCharacters: 120)
        guard !summary.isEmpty else { return title }
        guard !title.isEmpty else { return summary }
        guard summary.caseInsensitiveCompare(title) != .orderedSame else { return title }
        return "\(title)  ·  \(summary)"
    }

    private static func headerAttributedText(
        for item: TimelineItem,
        isExpanded: Bool,
        appearance: NSAppearance?
    ) -> NSAttributedString {
        let title = displayTitle(for: item)
        // Resolve a concrete reading color before applying alpha. AppKit's
        // `secondaryLabelColor.withAlphaComponent(...)` can lose its dynamic
        // role and render as glare-level label white in an attributed field.
        let softenedReadingColor = OnyxTheme.readingNSColor(for: appearance)
            .withAlphaComponent(0.86)
        guard item.kind.isRoutineActivity else {
            return NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: OnyxTypography.reading, weight: .semibold),
                    .foregroundColor: OnyxTheme.strongNSColor(for: appearance),
                ]
            )
        }

        if isExpanded {
            return NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: OnyxTypography.reading, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        let summary = compactSummary(for: item, maximumCharacters: 120)
        guard !summary.isEmpty,
              !title.isEmpty,
              summary.caseInsensitiveCompare(title) != .orderedSame else {
            return NSAttributedString(
                string: title.isEmpty ? summary : title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: OnyxTypography.reading, weight: .regular),
                    .foregroundColor: softenedReadingColor,
                ]
            )
        }

        let headline = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: OnyxTypography.reading, weight: .regular),
                .foregroundColor: softenedReadingColor,
            ]
        )
        headline.append(
            NSAttributedString(
                string: "  ·  \(summary)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: OnyxTypography.reading, weight: .regular),
                    // Failure output is the useful part of this compact row.
                    // Keep it readable while the small red disclosure conveys
                    // severity; ordinary implementation output stays quieter.
                    .foregroundColor: item.status == .failed
                        ? NSColor.secondaryLabelColor
                        : NSColor.tertiaryLabelColor,
                ]
            )
        )
        return headline
    }

    private func detailText(for item: TimelineItem, collapsed: Bool) -> String {
        guard !collapsed else { return "" }
        let detail = Self.visibleDetail(for: item)
        return detail
    }

    static func visibleDetail(for item: TimelineItem) -> String {
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard item.kind == .assistantMessage else { return detail }
        let normalized = detail
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let protocolLabels: Set<String> = [
            "final", "final_answer", "finalanswer", "commentary", "analysis",
            "assistant_message", "assistantmessage",
        ]
        // Usage is retained on the timeline item for persistence, accounting,
        // and model-ranking surfaces, but it is not conversation content. The
        // provider adapter currently emits `Token usage: ...`; the broader
        // marker check also covers older persisted forms such as
        // `1,024 input tokens` without hiding ordinary assistant metadata.
        let compactNormalized = normalized.filter { $0.isLetter || $0.isNumber }
        let usageMarkers = [
            "tokenusage", "inputtokens", "outputtokens", "prompttokens",
            "completiontokens", "responsetokens", "totaltokens",
        ]
        let isTokenUsage = usageMarkers.contains { compactNormalized.contains($0) }
        return protocolLabels.contains(normalized) || isTokenUsage ? "" : detail
    }

    private func statusText(for status: TimelineItemStatus) -> String {
        switch status {
        case .pending: "Queued"
        case .running: "Running"
        // Completion is the normal state and is already implied by the event
        // remaining in history. Repeating "Done" on every row creates noise.
        case .completed: ""
        case .failed: "Failed"
        case .declined: "Declined"
        }
    }

    private func accessibilityStatusText(for status: TimelineItemStatus) -> String {
        switch status {
        case .pending: "Queued"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .declined: "Declined"
        }
    }

    private func disclosureTintColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .pending: OnyxTheme.electricNSColor(for: effectiveAppearance).withAlphaComponent(0.78)
        case .running: OnyxTheme.electricNSColor(for: effectiveAppearance).withAlphaComponent(0.90)
        case .completed: .tertiaryLabelColor
        case .failed: OnyxTheme.destructiveNSColor(for: effectiveAppearance)
        case .declined: OnyxTheme.warningNSColor(for: effectiveAppearance)
        }
    }

    private func statusTextColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .failed: OnyxTheme.destructiveNSColor(for: effectiveAppearance)
        case .declined: OnyxTheme.warningNSColor(for: effectiveAppearance)
        case .running, .pending: OnyxTheme.electricNSColor(for: effectiveAppearance)
        case .completed: .secondaryLabelColor
        }
    }

    private func avatarGlyph(for kind: TimelineItemKind) -> String {
        switch kind {
        case .assistantMessage: "◆"
        case .reasoning: "◇"
        case .command: "›_"
        case .fileChange: "±"
        case .tool: "⌁"
        case .plan: "☷"
        case .approval: "!"
        case .error: "×"
        case .system: "·"
        case .userMessage: ""
        }
    }

    private func activityIconColor(
        for kind: TimelineItemKind,
        status: TimelineItemStatus
    ) -> NSColor {
        switch status {
        case .failed:
            return OnyxTheme.destructiveNSColor(for: effectiveAppearance)
        case .declined:
            return OnyxTheme.warningNSColor(for: effectiveAppearance)
        case .pending, .running:
            return OnyxTheme.electricNSColor(for: effectiveAppearance)
        case .completed:
            break
        }
        switch kind {
        case .error:
            return OnyxTheme.destructiveNSColor(for: effectiveAppearance)
        case .approval:
            return OnyxTheme.warningNSColor(for: effectiveAppearance)
        case .plan, .reasoning:
            return OnyxTheme.irisNSColor(for: effectiveAppearance)
        case .command, .fileChange, .tool, .system:
            return .tertiaryLabelColor
        case .assistantMessage, .userMessage:
            return .clear
        }
    }

    private func backgroundColor(for kind: TimelineItemKind) -> NSColor {
        switch kind {
        case .userMessage:
            // User intent gets the same restrained violet wash as selection.
            // The bubble stays dark; it simply reads as authored/decisive at a
            // glance instead of becoming another neutral card.
            OnyxTheme.irisNSColor(for: effectiveAppearance).withAlphaComponent(0.11)
        case .error:
            OnyxTheme.destructiveNSColor(for: effectiveAppearance).withAlphaComponent(0.09)
        case .approval:
            OnyxTheme.warningNSColor(for: effectiveAppearance).withAlphaComponent(0.10)
        case _ where kind.isActivity:
            NSColor.controlBackgroundColor.withAlphaComponent(0.38)
        default:
            .clear
        }
    }

    private static let attachmentSpacing: CGFloat = 8
    private static let linkSpacing: CGFloat = 6

    struct Metrics {
        let avatarX: CGFloat
        let contentX: CGFloat
        let contentWidth: CGFloat
        let top: CGFloat
        let titleHeight: CGFloat
        let titleGap: CGFloat
        let summaryHeight: CGFloat
        let bodyHeight: CGFloat
        let attachmentGap: CGFloat
        let attachmentColumns: Int
        let attachmentWidth: CGFloat
        let attachmentHeight: CGFloat
        let attachmentsHeight: CGFloat
        let linkGap: CGFloat
        let linkHeight: CGFloat
        let linksHeight: CGFloat
        let detailGap: CGFloat
        let detailHeight: CGFloat
        let bottom: CGFloat
        let headerHeight: CGFloat
        let statusWidth: CGFloat
        let isCollapsed: Bool
    }
}

/// A native, keyboard- and VoiceOver-accessible link row for non-image tool
/// results. URL validation happens in the provider projection; this view only
/// opens the already-approved http(s) destination.
final class TranscriptResourceLinkView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let link: TimelineResourceLink

    init(link: TimelineResourceLink) {
        self.link = link
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor

        titleLabel.stringValue = "↗  " + link.title
        titleLabel.font = .systemFont(ofSize: OnyxTypography.secondary, weight: .medium)
        titleLabel.textColor = .linkColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.stringValue = link.detail ?? link.url.host ?? link.url.absoluteString
        detailLabel.font = .systemFont(ofSize: OnyxTypography.metadata)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel("Open " + link.title)
        setAccessibilityValue(link.url.absoluteString)
        setAccessibilityHelp("Opens the tool result in your default browser.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(
            x: 12,
            y: bounds.height - 21,
            width: max(0, bounds.width - 24),
            height: 16
        )
        detailLabel.frame = NSRect(
            x: 12,
            y: 5,
            width: max(0, bounds.width - 24),
            height: 14
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = openLink()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49, openLink() { return }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        openLink()
    }

    @discardableResult
    private func openLink() -> Bool {
        NSWorkspace.shared.open(link.url)
    }
}

final class TranscriptAttachmentView: NSView {
    typealias ThumbnailLoader = @Sendable (
        TimelineAttachmentSource,
        String,
        Int
    ) async throws -> NSImage

    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Loading image…")
    private let spinner = NSProgressIndicator()
    private let attachment: TimelineAttachment
    private var loadTask: Task<Void, Never>?
    private var previewImage: NSImage?

    init(
        attachment: TimelineAttachment,
        thumbnailLoader: @escaping ThumbnailLoader = { source, cacheIdentity, maximumPixelSize in
            try await TranscriptImageLoader.shared.loadThumbnail(
                from: source,
                cacheIdentity: cacheIdentity,
                maximumPixelSize: maximumPixelSize
            )
        }
    ) {
        self.attachment = attachment
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.38).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.isHidden = true
        imageView.toolTip = "Open image preview"
        addSubview(imageView)

        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: OnyxTypography.secondary)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        addSubview(statusLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        addSubview(spinner)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(attachment.accessibilityLabel) preview")
        setAccessibilityHelp("Click to open a larger preview.")
        let source = attachment.source
        let cacheIdentity = attachment.cacheIdentity
        loadTask = Task { [weak self, source, cacheIdentity, thumbnailLoader] in
            do {
                let image = try await thumbnailLoader(source, cacheIdentity, 900)
                guard !Task.isCancelled, let self else { return }
                show(image)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                showFailure()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        statusLabel.frame = NSRect(x: 16, y: bounds.midY - 18, width: max(0, bounds.width - 32), height: 36)
        spinner.frame = NSRect(x: bounds.midX - 8, y: bounds.midY + 24, width: 16, height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard presentPreview() else {
            super.mouseDown(with: event)
            return
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49, presentPreview() { return }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        presentPreview()
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    @MainActor
    private func show(_ image: NSImage) {
        previewImage = image
        imageView.image = image
        imageView.isHidden = false
        statusLabel.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        loadTask = nil
    }

    @MainActor
    private func showFailure() {
        statusLabel.stringValue = "Image unavailable"
        statusLabel.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        setAccessibilityHelp("The image could not be loaded.")
        loadTask = nil
    }

    @MainActor
    @discardableResult
    private func presentPreview() -> Bool {
        guard let previewImage else { return false }
        AttachmentPreviewController.shared.present(image: previewImage, title: attachment.accessibilityLabel)
        return true
    }
}

actor TranscriptImageLoader {
    static let shared = TranscriptImageLoader()

    enum LoaderError: Error {
        case malformedDataURL
        case unsupportedSource
        case invalidResponse
        case responseTooLarge
        case invalidImage
    }

    private static let maximumEncodedBytes = 24 * 1_024 * 1_024
    private static let maximumDownloadBytes = 24 * 1_024 * 1_024
    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 0,
            diskPath: nil
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage, any Error>] = [:]

    init() {
        cache.countLimit = 96
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func loadThumbnail(
        from source: TimelineAttachmentSource,
        cacheIdentity: String,
        maximumPixelSize: Int
    ) async throws -> NSImage {
        try Task.checkCancellation()
        let key = Self.effectiveCacheKey(
            baseIdentity: cacheIdentity,
            source: source,
            maximumPixelSize: maximumPixelSize
        )
        let objectKey = key as NSString
        if let cached = cache.object(forKey: objectKey) { return cached }
        if let pending = inFlight[key] {
            let image = try await pending.value
            try Task.checkCancellation()
            return image
        }

        let pending = Task<NSImage, any Error> { [source] in
            let data = try await self.imageData(from: source)
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try Self.downsample(data: data, maximumPixelSize: maximumPixelSize)
            }.value
        }
        inFlight[key] = pending
        do {
            let image = try await pending.value
            inFlight.removeValue(forKey: key)
            let cost = max(1, Int(image.size.width * image.size.height * 4))
            cache.setObject(image, forKey: objectKey, cost: cost)
            try Task.checkCancellation()
            return image
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }

    private func imageData(from source: TimelineAttachmentSource) async throws -> Data {
        switch source {
        case let .dataURL(value):
            return try Self.decodeImageDataURL(value)
        case let .localFilePath(path):
            try Task.checkCancellation()
            let expandedPath = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath, isDirectory: false)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw LoaderError.unsupportedSource }
            if let size = values.fileSize, size > Self.maximumEncodedBytes {
                throw LoaderError.responseTooLarge
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        case let .remoteURL(url):
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
                throw LoaderError.unsupportedSource
            }
            let (bytes, response) = try await Self.urlSession.bytes(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw LoaderError.invalidResponse
            }
            try Self.validateExpectedContentLength(response.expectedContentLength)
            if let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !contentType.hasPrefix("image/") {
                throw LoaderError.invalidResponse
            }
            var data = Data()
            data.reserveCapacity(max(0, min(Int(response.expectedContentLength), Self.maximumDownloadBytes)))
            for try await byte in bytes {
                try Task.checkCancellation()
                try Self.appendRemoteByte(byte, to: &data)
            }
            return data
        }
    }

    static func decodeImageDataURL(
        _ value: String,
        maximumDecodedBytes: Int = maximumEncodedBytes
    ) throws -> Data {
        guard let comma = value.firstIndex(of: ",") else { throw LoaderError.malformedDataURL }
        guard value.distance(from: value.startIndex, to: comma) <= 256 else {
            throw LoaderError.malformedDataURL
        }
        let metadata = value[..<comma].lowercased()
        guard metadata.hasPrefix("data:image/"), metadata.contains(";base64") else {
            throw LoaderError.malformedDataURL
        }
        let encoded = value[value.index(after: comma)...]
        let maximumEncodedCharacters = ((maximumDecodedBytes + 2) / 3) * 4
        guard maximumDecodedBytes >= 0,
              encoded.utf8.count <= maximumEncodedCharacters,
              let data = Data(base64Encoded: String(encoded)),
              data.count <= maximumDecodedBytes else {
            throw LoaderError.malformedDataURL
        }
        return data
    }

    static func validateExpectedContentLength(
        _ length: Int64,
        maximumBytes: Int = maximumDownloadBytes
    ) throws {
        if length > Int64(maximumBytes) { throw LoaderError.responseTooLarge }
    }

    static func appendRemoteByte(
        _ byte: UInt8,
        to data: inout Data,
        maximumBytes: Int = maximumDownloadBytes
    ) throws {
        guard data.count < maximumBytes else { throw LoaderError.responseTooLarge }
        data.append(byte)
    }

    private static func effectiveCacheKey(
        baseIdentity: String,
        source: TimelineAttachmentSource,
        maximumPixelSize: Int
    ) -> String {
        var key = "\(baseIdentity):\(maximumPixelSize)"
        if case let .localFilePath(path) = source {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            key += ":\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? -1)"
        }
        return key
    }

    static func downsample(data: Data, maximumPixelSize: Int) throws -> NSImage {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw LoaderError.invalidImage
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw LoaderError.invalidImage
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

@MainActor
private final class AttachmentPreviewController: NSWindowController, NSWindowDelegate {
    static let shared = AttachmentPreviewController()

    private init() {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        let scrollView = NSScrollView()
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(image: NSImage, title: String) {
        guard let window, let scrollView = window.contentView as? NSScrollView,
              let imageView = scrollView.documentView as? NSImageView else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        window.title = title
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

extension TimelineItemKind {
    var rendersMarkdown: Bool {
        switch self {
        case .userMessage, .assistantMessage, .reasoning, .plan, .system:
            true
        case .command, .fileChange, .tool, .approval, .error:
            false
        }
    }

    var isActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool, .plan, .approval, .system, .error:
            true
        case .userMessage, .assistantMessage:
            false
        }
    }

    /// Verbose implementation activity is opt-in detail. Plans retain a
    /// concise progress line in the transcript and expand in place; approvals
    /// and failures stay fully visible because they require attention.
    var isCollapsibleActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool, .plan:
            true
        case .approval, .error, .system, .userMessage, .assistantMessage:
            false
        }
    }

    /// High-frequency implementation events should remain visually quiet in
    /// the conversation. They are still independently expandable and keep
    /// their stable runtime identities.
    var isRoutineActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool:
            true
        case .plan, .approval, .error, .system, .userMessage, .assistantMessage:
            false
        }
    }

    /// Reserve strong surfaces for states that require attention. Plans stay
    /// visible in the transcript, but read as content instead of another card.
    var isProminentActivity: Bool {
        switch self {
        case .approval, .error, .system:
            true
        case .plan, .reasoning, .command, .fileChange, .tool, .userMessage, .assistantMessage:
            false
        }
    }

    var defaultExpanded: Bool {
        !isCollapsibleActivity
    }
}

extension TimelineItem {
    /// Routine implementation output remains a compact status line while it
    /// is queued or running. Only exceptional outcomes become strong surfaces;
    /// live progress remains visible through its tinted leading disclosure and
    /// accessible status without turning the transcript back into cards.
    var isProminentActivity: Bool {
        kind.isProminentActivity
    }
}

private extension String {
    func boundingHeight(width: CGFloat, font: NSFont) -> CGFloat {
        let rect = (self as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(font.pointSize + 5, ceil(rect.height) + 2)
    }

    /// Keeps short user messages conversational instead of stretching their
    /// bubble across the transcript. Work is deliberately bounded so pasting a
    /// very large prompt cannot make layout scan the complete payload.
    func preferredBubbleWidth(fontSize: CGFloat) -> CGFloat {
        let sample = String(prefix(1_200))
        let widestLine = sample
            .components(separatedBy: .newlines)
            .prefix(16)
            .max(by: { $0.count < $1.count })
            ?? ""
        let font = NSFont.systemFont(ofSize: fontSize)
        let measured = (widestLine as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured + 28)
    }
}

private extension NSAttributedString {
    func boundingHeight(width: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        let rect = boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let baseFont = attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        return max((baseFont?.pointSize ?? 14) + 5, ceil(rect.height) + 2)
    }
}
