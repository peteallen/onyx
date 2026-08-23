import AppKit
import ImageIO
import SwiftUI

struct NativeTranscriptView: NSViewControllerRepresentable {
    let items: [TimelineItem]
    var isAwaitingResponse = false
    var workingLabel = "Working"
    var revision: UInt64? = nil
    var changeHint: TranscriptCollectionUpdate.Hint? = nil

    func makeNSViewController(context: Context) -> TranscriptViewController {
        TranscriptViewController()
    }

    func updateNSViewController(_ controller: TranscriptViewController, context: Context) {
        controller.update(
            items: items,
            isAwaitingResponse: isAwaitingResponse,
            workingLabel: workingLabel,
            revision: revision,
            changeHint: changeHint
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
        let hasStreamingAssistant = items.reversed()
            .prefix(while: { $0.kind != .userMessage })
            .contains {
                $0.kind == .assistantMessage && $0.status == .running && !$0.body.isEmpty
            }
        return Self(isVisible: !hasStreamingAssistant, label: label)
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

        while let tailGroup = groups.last, tailGroup.range.upperBound > itemStart {
            groups.removeLast()
        }
        let groupStart = groups.count
        groups.append(
            contentsOf: self.groups(
                for: newItems,
                startingAt: itemStart,
                instrumentation: &instrumentation
            )
        )
        return AppendResult(itemStart: itemStart, groupStart: groupStart)
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

        while let tailGroup = groups.last, tailGroup.range.upperBound > itemStart {
            groups.removeLast()
        }
        let groupStart = groups.count
        groups.append(
            contentsOf: self.groups(
                for: newItems,
                startingAt: itemStart,
                instrumentation: &instrumentation
            )
        )
        return AppendResult(itemStart: itemStart, groupStart: groupStart)
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
        case .append, .reloadAll:
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
    case reloadAll

    struct PlanningInstrumentation: Equatable {
        fileprivate(set) var inspectedItemCount = 0
        fileprivate(set) var hintedUpdateCount = 0
    }

    enum Hint: Equatable {
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
        case .unchanged, .append:
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
    /// The transcript is prose first. Keeping its outer row to 760 points
    /// leaves roughly a 700-point text measure after message insets, which is
    /// comfortable at the app's 15-point reading size and aligns with the
    /// composer below it.
    static let maximumReadableWidth: CGFloat = 760
    // Normal panes keep a quiet gutter; very narrow transition frames let
    // that gutter yield before they let a row overflow.
    static let preferredHorizontalInset: CGFloat = 24
    static let layoutSafetyWidth: CGFloat = 1

    let itemWidth: CGFloat
    let horizontalInset: CGFloat

    init(collectionWidth rawCollectionWidth: CGFloat) {
        let collectionWidth = rawCollectionWidth.isFinite
            ? max(0, rawCollectionWidth)
            : 0
        guard collectionWidth > Self.layoutSafetyWidth else {
            itemWidth = 0
            horizontalInset = 0
            return
        }

        // Margins stay at their preferred size for normal panes, but yield
        // during transient narrow layout passes instead of forcing a 320pt
        // row into a smaller collection view.
        itemWidth = min(
            Self.maximumReadableWidth,
            max(
                1,
                collectionWidth
                    - Self.preferredHorizontalInset * 2
                    - Self.layoutSafetyWidth
            )
        )
        horizontalInset = max(
            0,
            (collectionWidth - itemWidth - Self.layoutSafetyWidth) / 2
        )
    }
}

private final class TranscriptCollectionFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        return collectionView.bounds.width != newBounds.width
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

final class TranscriptViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
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

    private struct AppendProjectionChange {
        let displayStart: Int
        let oldDisplayCount: Int
        let oldTailIDs: [String]
        let newTailIDs: [String]
        let reloadsExistingGroup: Bool
        let requiresReload: Bool

        var preservesExistingRows: Bool {
            !requiresReload && newTailIDs.starts(with: oldTailIDs)
        }
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
    /// Collection rows are presentation-only. A collapsed activity group
    /// replaces its contiguous children with one summary row; expanding it
    /// puts the original children back at their stable positions.
    private var displayRows: [DisplayRow] = []
    private var activityGroups: [TranscriptActivityGroup] = []
    private var displayIndexByItemIndex: [Int: Int] = [:]
    private var groupDisplayIndexByItemIndex: [Int: Int] = [:]
    private var expandedActivityGroupIDs = Set<String>()
    /// Expansion follows provider-stable timeline IDs, never collection
    /// indexes. Streaming and insertion can recycle cells while preserving a
    /// row's identity.
    private var expandedItemIDs = Set<String>()
    private var hasScheduledFollowScroll = false

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
        changeHint: TranscriptCollectionUpdate.Hint? = nil
    ) {
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
        // Keep the old presentation row mounted while applying transcript
        // mutations.  The pending row is always the final collection item;
        // deferring this state change lets AppKit reconcile transcript inserts
        // and the pending-row insert/delete against the correct old item
        // count, without a full reload of a potentially long history.
        let oldPendingResponse = pendingResponse
        let pendingResponseChanged = newPendingResponse != oldPendingResponse
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
            case .unchanged, .append, .reloadAll: []
            }
            for index in changedIndices where newItems.indices.contains(index) {
                if !newItems[index].kind.isCollapsibleActivity {
                    expandedItemIDs.remove(newItems[index].id)
                }
            }
        }

        var appendProjectionChange: AppendProjectionChange?
        var tailProjectionChange: TailProjectionChange?
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
            activityGroups = newGroups
            displayRows = makeDisplayRows(items: newItems, groups: newGroups)
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

        if let appendProjectionChange {
            applyAppendProjectionChange(appendProjectionChange)
        } else if let tailProjectionChange {
            applyTailProjectionChange(tailProjectionChange)
        } else if groupingStructureChanged {
            collectionView.reloadData()
        } else {
            switch update {
            case .unchanged:
                break
            case let .tailChange(index):
                reloadRows(IndexSet(integer: index))
            case let .rowChanges(indices):
                reloadRows(indices)
            case .append:
                // Handled by the incremental projection branch above.
                break
            case .reloadAll:
                collectionView.reloadData()
            }
        }

        // Update the UI-owned response indicator independently.  Showing or
        // hiding it should touch one collection item at the tail, not cause
        // every Markdown-heavy transcript cell to be recreated.  This runs
        // after transcript mutations while `pendingResponse` still describes
        // the old data-source count, so insert/delete validation remains
        // consistent even when a streamed item and the indicator change in
        // the same SwiftUI update.
        pendingResponse = newPendingResponse
        if pendingResponseChanged {
            applyPendingResponseChange(
                from: oldPendingResponse,
                to: newPendingResponse
            )
        }

        if shouldFollow || oldItems.isEmpty || pendingResponse.isVisible {
            scheduleFollowScroll()
        }
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

    private func applyPendingResponseChange(
        from oldResponse: TranscriptPendingResponse,
        to newResponse: TranscriptPendingResponse
    ) {
        let oldVisible = oldResponse.isVisible
        let newVisible = newResponse.isVisible
        let pendingIndex = displayRows.count

        switch (oldVisible, newVisible) {
        case (false, true):
            collectionView.insertItems(
                at: [IndexPath(item: pendingIndex, section: 0)]
            )
        case (true, false):
            collectionView.deleteItems(
                at: [IndexPath(item: pendingIndex, section: 0)]
            )
        case (true, true) where oldResponse.label != newResponse.label:
            collectionView.reloadItems(
                at: [IndexPath(item: pendingIndex, section: 0)]
            )
        case (false, false), (true, true):
            break
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayRows.count + (pendingResponse.isVisible ? 1 : 0)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        if pendingResponse.isVisible, indexPath.item == displayRows.count {
            let item = collectionView.makeItem(
                withIdentifier: Self.pendingItemIdentifier,
                for: indexPath
            )
            (item as? TranscriptPendingCollectionItem)?.configure(label: pendingResponse.label)
            return item
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
                onToggle: { [weak self] expanded in
                    self?.setExpanded(expanded, for: timelineItem.id)
                }
            )
            return transcriptItem
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = flowMetrics.itemWidth
        if pendingResponse.isVisible, indexPath.item == displayRows.count {
            return NSSize(width: width, height: TranscriptPendingResponseView.rowHeight)
        }
        switch displayRows[indexPath.item] {
        case .activityGroup:
            return NSSize(width: width, height: TranscriptActivityGroupView.rowHeight)
        case let .item(index):
            let item = items[index]
            let expanded = isExpanded(item)
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
            left: metrics.horizontalInset,
            bottom: 24,
            right: metrics.horizontalInset
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if layoutState.readableWidthDidChange(to: readableWidth) {
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

    private func makeDisplayRows(
        items: [TimelineItem],
        groups: [TranscriptActivityGroup]
    ) -> [DisplayRow] {
        makeDisplayRows(items: items, groups: groups[...], startingAt: 0)
    }

    private func makeDisplayRows(
        items: [TimelineItem],
        groups: ArraySlice<TranscriptActivityGroup>,
        startingAt initialIndex: Int
    ) -> [DisplayRow] {
        var groupsByStart: [Int: TranscriptActivityGroup] = [:]
        groupsByStart.reserveCapacity(groups.count)
        for group in groups {
            groupsByStart[group.range.lowerBound] = group
        }

        var rows: [DisplayRow] = []
        rows.reserveCapacity(max(0, items.count - initialIndex))
        var index = initialIndex
        while index < items.count {
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

    private func appendProjection(
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        appendedRange: Range<Int>
    ) -> AppendProjectionChange {
        let oldDisplayCount = displayRows.count
        guard let result = TranscriptActivityGrouping.append(
            to: &activityGroups,
            oldItems: oldItems,
            newItems: newItems,
            appendedRange: appendedRange
        ) else {
            activityGroups = TranscriptActivityGrouping.groups(for: newItems)
            displayRows = makeDisplayRows(items: newItems, groups: activityGroups)
            rebuildDisplayIndex()
            return AppendProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                reloadsExistingGroup: false,
                requiresReload: true
            )
        }

        let displayStart: Int
        if result.itemStart == oldItems.count {
            displayStart = oldDisplayCount
        } else if let groupIndex = groupDisplayIndexByItemIndex[result.itemStart] {
            displayStart = groupIndex
        } else if let itemIndex = displayIndexByItemIndex[result.itemStart] {
            displayStart = itemIndex
        } else {
            activityGroups = TranscriptActivityGrouping.groups(for: newItems)
            displayRows = makeDisplayRows(items: newItems, groups: activityGroups)
            rebuildDisplayIndex()
            return AppendProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                reloadsExistingGroup: false,
                requiresReload: true
            )
        }

        let oldTailIDs = displayRows[displayStart...].map(\.id)
        displayRows.removeSubrange(displayStart...)
        let tailRows = makeDisplayRows(
            items: newItems,
            groups: activityGroups[result.groupStart...],
            startingAt: result.itemStart
        )
        displayRows.append(contentsOf: tailRows)
        let newTailIDs = tailRows.map(\.id)
        rebuildDisplayIndex(
            fromDisplayIndex: displayStart,
            itemIndexStart: result.itemStart,
            oldItemCount: oldItems.count
        )

        return AppendProjectionChange(
            displayStart: displayStart,
            oldDisplayCount: oldDisplayCount,
            oldTailIDs: oldTailIDs,
            newTailIDs: newTailIDs,
            reloadsExistingGroup: result.itemStart < oldItems.count
                && tailRows.first.map { row in
                    if case .activityGroup = row { return true }
                    return false
                } == true,
            requiresReload: false
        )
    }

    private func applyAppendProjectionChange(_ change: AppendProjectionChange) {
        guard change.preservesExistingRows else {
            collectionView.reloadData()
            return
        }

        // `appendProjection` has already installed the new display-row
        // snapshot because the collection view's data source must be able to
        // render the inserted cells immediately. When an eight-item activity
        // rollup reaches its bound and the next activity becomes a new row,
        // the snapshot grows *and* the surviving rollup changes. Issuing the
        // reload first asks AppKit to reload against the old item count while
        // the data source reports the new count, which raises
        // `NSInternalInconsistencyException` during hosted SwiftUI layout.
        // Apply both topology and content changes as one collection update so
        // AppKit validates the old/new counts together.
        let insertedPaths: Set<IndexPath>
        if displayRows.count > change.oldDisplayCount {
            insertedPaths = Set(
                (change.oldDisplayCount..<displayRows.count).map {
                    IndexPath(item: $0, section: 0)
                }
            )
        } else {
            insertedPaths = []
        }
        let reloadPaths: Set<IndexPath> = change.reloadsExistingGroup
            ? [IndexPath(item: change.displayStart, section: 0)]
            : []
        guard !insertedPaths.isEmpty || !reloadPaths.isEmpty else { return }

        collectionView.performBatchUpdates({
            if !insertedPaths.isEmpty {
                collectionView.insertItems(at: insertedPaths)
            }
            if !reloadPaths.isEmpty {
                collectionView.reloadItems(at: reloadPaths)
            }
        }, completionHandler: nil)
    }

    private func replaceChangedTailProjection(
        oldItems: [TimelineItem],
        newItems: [TimelineItem],
        changedIndex: Int
    ) -> TailProjectionChange {
        let oldDisplayCount = displayRows.count
        let oldGroupCount = activityGroups.count
        let previousLastGroupID = activityGroups.last?.id
        guard let result = TranscriptActivityGrouping.replaceChangedTail(
            in: &activityGroups,
            oldItems: oldItems,
            newItems: newItems,
            changedIndex: changedIndex
        ) else {
            activityGroups = TranscriptActivityGrouping.groups(for: newItems)
            displayRows = makeDisplayRows(items: newItems, groups: activityGroups)
            rebuildDisplayIndex()
            return TailProjectionChange(
                displayStart: 0,
                oldDisplayCount: oldDisplayCount,
                oldTailIDs: [],
                newTailIDs: [],
                requiresReload: true
            )
        }

        if result.groupStart < oldGroupCount,
           let previousLastGroupID,
           !activityGroups[result.groupStart...].contains(where: { $0.id == previousLastGroupID }) {
            expandedActivityGroupIDs.remove(previousLastGroupID)
        }

        let displayStart: Int
        if let groupIndex = groupDisplayIndexByItemIndex[result.itemStart] {
            displayStart = groupIndex
        } else if let itemIndex = displayIndexByItemIndex[result.itemStart] {
            displayStart = itemIndex
        } else {
            activityGroups = TranscriptActivityGrouping.groups(for: newItems)
            displayRows = makeDisplayRows(items: newItems, groups: activityGroups)
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
        displayRows.removeSubrange(displayStart...)
        let tailRows = makeDisplayRows(
            items: newItems,
            groups: activityGroups[result.groupStart...],
            startingAt: result.itemStart
        )
        displayRows.append(contentsOf: tailRows)
        rebuildDisplayIndex(
            fromDisplayIndex: displayStart,
            itemIndexStart: result.itemStart,
            oldItemCount: oldItems.count
        )

        return TailProjectionChange(
            displayStart: displayStart,
            oldDisplayCount: oldDisplayCount,
            oldTailIDs: oldTailIDs,
            newTailIDs: tailRows.map(\.id),
            requiresReload: false
        )
    }

    private func applyTailProjectionChange(_ change: TailProjectionChange) {
        guard !change.requiresReload else {
            collectionView.reloadData()
            return
        }

        let newRange = change.displayStart..<displayRows.count
        if change.oldTailIDs == change.newTailIDs {
            let indexPaths = Set(newRange.map { IndexPath(item: $0, section: 0) })
            guard !indexPaths.isEmpty else { return }
            // Reloading is the only mutation; the flow layout now invalidates
            // its delegate metrics atomically when its width changes.
            collectionView.reloadItems(at: indexPaths)
            return
        }

        // A changed projection replaces collection topology (for example, a
        // live tool row joining a compact activity group). A single reload is
        // safer than delete/insert batch mutations while SwiftUI is laying out
        // the hosted controller, and this path is much rarer than streaming.
        collectionView.reloadData()
    }

    private func rebuildDisplayIndex() {
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
    }

    private func rebuildDisplayIndex(
        fromDisplayIndex displayStart: Int,
        itemIndexStart: Int,
        oldItemCount: Int
    ) {
        if itemIndexStart < oldItemCount {
            for index in itemIndexStart..<oldItemCount {
                displayIndexByItemIndex.removeValue(forKey: index)
                groupDisplayIndexByItemIndex.removeValue(forKey: index)
            }
        }
        for displayIndex in displayStart..<displayRows.count {
            switch displayRows[displayIndex] {
            case let .item(index):
                displayIndexByItemIndex[index] = displayIndex
            case let .activityGroup(group):
                for index in group.range {
                    groupDisplayIndexByItemIndex[index] = displayIndex
                    if !expandedActivityGroupIDs.contains(group.id) {
                        displayIndexByItemIndex[index] = displayIndex
                    }
                }
            }
        }
    }

    private func reloadRows(_ indices: IndexSet) {
        var displayIndices = IndexSet(indices.compactMap { displayIndexByItemIndex[$0] })
        // A child's title can contribute to the semantic rollup. Refresh its
        // header too when the group is expanded; the child row still reloads
        // through the regular display-index map.
        for index in indices {
            if let groupIndex = groupDisplayIndexByItemIndex[index] {
                displayIndices.insert(groupIndex)
            }
        }
        guard !displayIndices.isEmpty else { return }
        let indexPaths = Set(displayIndices.map { IndexPath(item: $0, section: 0) })
        // Reloading the items is the single layout mutation. A separate manual
        // invalidation here is re-entrant when this update is driven by an
        // `NSHostingView` layout pass and has caused production crashes.
        collectionView.reloadItems(at: indexPaths)
    }

    private func isExpanded(_ item: TimelineItem) -> Bool {
        item.kind.isCollapsibleActivity ? expandedItemIDs.contains(item.id) : true
    }

    private func setExpanded(_ expanded: Bool, for itemID: String) {
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
        displayRows = makeDisplayRows(items: items, groups: activityGroups)
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

private final class TranscriptPendingResponseView: NSView {
    static let rowHeight: CGFloat = 34

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Working")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        addSubview(spinner)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Assistant response status")
        setAccessibilityValue("Working")
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
        let leading: CGFloat = 4
        let spinnerSize: CGFloat = 16
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
            x: leading + 24,
            y: floor((bounds.height - labelHeight) / 2),
            width: max(0, bounds.width - leading - 24),
            height: labelHeight
        )
    }

    func configure(label value: String) {
        label.stringValue = value
        setAccessibilityValue(value)
        spinner.startAnimation(nil)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        titleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.86)
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
        let disclosureWidth: CGFloat = 22
        let textX: CGFloat = 27
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
                    .font: titleLabel.font ?? NSFont.systemFont(ofSize: 12),
                    .foregroundColor: titleLabel.textColor ?? NSColor.secondaryLabelColor,
                ]
            ),
            width: titleLabel.bounds.width
        )
        expansionControl.frame = NSRect(
            x: 1,
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
        onToggle: ((Bool) -> Void)? = nil
    ) {
        (view as? TranscriptCellView)?.configure(
            with: item,
            isExpanded: isExpanded,
            onToggle: onToggle
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
        case heading(Int)
        case quote
        case code
        case thematicBreak
    }

    private struct BlockLine {
        let prefix: String
        let content: String
        let style: BlockStyle
    }

    static func attributedString(
        markdown source: String,
        baseFont: NSFont,
        textColor: NSColor = .labelColor
    ) -> NSAttributedString {
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

        var renderedLines: [NSAttributedString] = []
        renderedLines.reserveCapacity(min(256, max(1, byteCount / 48)))
        var fence: String?

        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = fence {
                if trimmed.hasPrefix(delimiter) {
                    fence = nil
                } else {
                    renderedLines.append(styledLine(BlockLine(prefix: "", content: line, style: .code), baseFont: baseFont, textColor: textColor))
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            renderedLines.append(styledLine(parseBlock(line), baseFont: baseFont, textColor: textColor))
        }

        let result = NSMutableAttributedString()
        for (index, line) in renderedLines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: plainAttributes)) }
            result.append(line)
        }
        if result.length > 0 {
            result.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: result.length)
            )
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

    /// Produces a marker-free preview without scanning or parsing the complete
    /// activity payload. Invalid Markdown simply remains readable plain text.
    static func compactPlainText(from source: Substring) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let hashes = content.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), content.dropFirst(hashes).first?.isWhitespace == true {
            return BlockLine(
                prefix: "",
                content: String(content.dropFirst(hashes)).trimmingCharacters(in: .whitespaces),
                style: .heading(hashes)
            )
        }

        if content.hasPrefix(">") {
            content.removeFirst()
            if content.first == " " { content.removeFirst() }
            return BlockLine(prefix: "│ ", content: content, style: .quote)
        }

        if content == "---" || content == "***" || content == "___" {
            return BlockLine(prefix: "", content: "────────────────", style: .thematicBreak)
        }

        var listPrefix: String?
        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            content.removeFirst(2)
            listPrefix = "• "
        } else {
            let digits = content.prefix(while: { $0.isNumber })
            let remainder = content.dropFirst(digits.count)
            if !digits.isEmpty,
               (remainder.hasPrefix(". ") || remainder.hasPrefix(") ")) {
                content = String(remainder.dropFirst(2))
                listPrefix = "\(digits). "
            }
        }

        if let listPrefix {
            var marker = listPrefix
            if content.hasPrefix("[ ] ") {
                content.removeFirst(4)
                marker = "☐ "
            } else if content.lowercased().hasPrefix("[x] ") {
                content.removeFirst(4)
                marker = "☑ "
            }
            let indentation = String(repeating: "  ", count: min(4, leadingCount / 2))
            return BlockLine(prefix: indentation + marker, content: content, style: .body)
        }

        return BlockLine(prefix: leading, content: content, style: .body)
    }

    private static func styledLine(
        _ block: BlockLine,
        baseFont: NSFont,
        textColor: NSColor
    ) -> NSAttributedString {
        let font: NSFont
        let color: NSColor
        switch block.style {
        case .body:
            font = baseFont
            color = textColor
        case let .heading(level):
            let sizes: [CGFloat] = [19, 17.5, 16.5, 15.5, 15, 15]
            font = .systemFont(ofSize: sizes[level - 1], weight: .semibold)
            color = textColor
        case .quote:
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            color = .secondaryLabelColor
        case .code:
            font = .monospacedSystemFont(ofSize: max(12.5, baseFont.pointSize - 1), weight: .regular)
            color = textColor
        case .thematicBreak:
            font = baseFont
            color = .separatorColor
        }

        let line = NSMutableAttributedString(
            string: block.prefix,
            attributes: [.font: font, .foregroundColor: color]
        )
        line.append(inlineMarkdown(block.content, font: font, textColor: color))
        if case .code = block.style, line.length > 0 {
            line.addAttribute(
                .backgroundColor,
                value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                range: NSRange(location: 0, length: line.length)
            )
        }
        return line
    }

    private static func inlineMarkdown(
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
                renderedFont = .monospacedSystemFont(ofSize: max(12.5, font.pointSize - 0.5), weight: .regular)
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                    range: range
                )
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { renderedFont = NSFontManager.shared.convert(font, toHaveTrait: traits) }
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

final class TranscriptCellView: NSView {
    static let maximumVisibleAttachments = TranscriptLayoutState.maximumVisibleAttachments
    static let maximumVisibleLinks = TranscriptLayoutState.maximumVisibleLinks
    private static let messageFontSize: CGFloat = 15
    private static let userBubbleHorizontalPadding: CGFloat = 14

    private let bubbleBackground = NSView()
    private let avatar = NSTextField(labelWithString: "◆")
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
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
    private(set) var isExpanded = true
    private var isExpandable = false

    var isCollapsed: Bool { isExpandable && !isExpanded }
    var canToggleExpansion: Bool { isExpandable }
    var messageBubbleFrame: NSRect { bubbleBackground.frame }

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

        avatar.font = .systemFont(ofSize: 12, weight: .semibold)
        avatar.textColor = NSColor.systemIndigo
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        summaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        summaryLabel.usesSingleLineMode = true
        bodyLabel.font = .systemFont(ofSize: Self.messageFontSize, weight: .regular)
        bodyLabel.textColor = .labelColor
        bodyLabel.isSelectable = true
        bodyLabel.allowsEditingTextAttributes = true
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 6
        statusLabel.layer?.masksToBounds = true

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        onToggle: ((Bool) -> Void)? = nil
    ) {
        removeMediaViews()
        self.item = item
        self.isExpandable = item.kind.isCollapsibleActivity
        self.isExpanded = self.isExpandable ? isExpanded : true
        self.onToggle = onToggle

        fullTitleAttributedText = Self.headerAttributedText(for: item, isExpanded: self.isExpanded)
        titleLabel.attributedStringValue = fullTitleAttributedText
        summaryLabel.stringValue = Self.compactSummary(for: item)
        bodyLabel.font = Self.bodyFont(for: item)
        // A collapsed activity may hide megabytes of provider output. Do not
        // duplicate and parse that payload into an attributed string until the
        // user actually opens the row.
        bodyLabel.attributedStringValue = self.isExpanded
            ? Self.bodyAttributedText(for: item)
            : NSAttributedString()
        detailLabel.stringValue = detailText(for: item, collapsed: self.isExpandable && !self.isExpanded)
        statusLabel.stringValue = statusText(for: item.status)
        avatar.stringValue = avatarGlyph(for: item.kind)
        avatar.textColor = activityIconColor(for: item.kind)
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
        statusLabel.layer?.backgroundColor = isProminentActivity
            ? statusBackgroundColor(for: item.status).cgColor
            : NSColor.clear.cgColor

        if self.isExpanded {
            rebuildMediaViews()
        }
        applyExpansionPresentation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        removeMediaViews()
        onToggle = nil
        item = nil
        fullTitleAttributedText = NSAttributedString()
        isExpandable = false
        isExpanded = true
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

    func toggleExpansion() {
        guard isExpandable else { return }
        isExpanded.toggle()
        if isExpanded {
            if let item {
                bodyLabel.attributedStringValue = Self.bodyAttributedText(for: item)
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
        fullTitleAttributedText = Self.headerAttributedText(for: item, isExpanded: isExpanded)
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
        let metrics = Self.metrics(for: item, width: bounds.width, isExpanded: isExpanded)
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
        let metrics = Self.metrics(for: item, width: bounds.width, isExpanded: isExpanded)
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
        let metrics = Self.metrics(for: item, width: bounds.width, isExpanded: isExpanded)
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
            width: max(0, metrics.contentWidth - metrics.statusWidth - 8),
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
            width: metrics.contentWidth,
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
            x: max(0, metrics.avatarX - 1),
            y: max(0, headerTop - max(22, metrics.headerHeight) + 2),
            width: isExpandable ? 22 : disclosureWidth,
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

    /// Legacy bounded measurement retained for callers that only need a
    /// conservative estimate. The live collection view uses the explicit
    /// expansion overload below, which renders every attachment/link when
    /// expanded.
    static func height(for item: TimelineItem, width: CGFloat) -> CGFloat {
        height(for: item, width: width, isExpanded: true, boundedMedia: true)
    }

    static func height(for item: TimelineItem, width: CGFloat, isExpanded: Bool) -> CGFloat {
        height(for: item, width: width, isExpanded: isExpanded, boundedMedia: false)
    }

    private static func height(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        boundedMedia: Bool
    ) -> CGFloat {
        let metrics = metrics(
            for: item,
            width: width,
            isExpanded: isExpanded,
            boundedMedia: boundedMedia
        )
        return metrics.top + metrics.titleHeight + metrics.titleGap
            + metrics.summaryHeight + metrics.bodyHeight
            + metrics.attachmentGap + metrics.attachmentsHeight
            + metrics.linkGap + metrics.linksHeight
            + metrics.detailGap + metrics.detailHeight + metrics.bottom
    }

    static func metrics(for item: TimelineItem, width: CGFloat) -> Metrics {
        metrics(for: item, width: width, isExpanded: true, boundedMedia: true)
    }

    static func metrics(for item: TimelineItem, width: CGFloat, isExpanded: Bool) -> Metrics {
        metrics(for: item, width: width, isExpanded: isExpanded, boundedMedia: false)
    }

    private static func metrics(
        for item: TimelineItem,
        width: CGFloat,
        isExpanded: Bool,
        boundedMedia: Bool
    ) -> Metrics {
        let isUser = item.kind == .userMessage
        let isActivity = item.kind.isActivity
        let isRoutineActivity = item.kind.isRoutineActivity
        let isCollapsed = item.kind.isCollapsibleActivity && !isExpanded
        let isExceptionalRoutineActivity = isRoutineActivity
            && (item.status == .failed || item.status == .declined)
        let isQuietRoutineActivity = isRoutineActivity
            && isCollapsed
            && !isExceptionalRoutineActivity
        let horizontalInset: CGFloat = isUser
            ? userBubbleHorizontalPadding
            : (isActivity ? (isQuietRoutineActivity ? 5 : 14) : 0)
        let userBubbleMaximum = min(560, width * 0.78)
        let preferredUserBubbleWidth = item.attachments.isEmpty && item.links.isEmpty
            ? item.body.preferredBubbleWidth(fontSize: messageFontSize)
            : max(360, width * 0.56)
        let userBubbleWidth = min(userBubbleMaximum, max(52, preferredUserBubbleWidth))
        let contentX: CGFloat = isUser
            ? max(0, width - userBubbleWidth) + horizontalInset
            : (isActivity ? (isQuietRoutineActivity ? 22 : 34) + horizontalInset : 28)
        let trailing: CGFloat = isUser ? horizontalInset : (isActivity ? horizontalInset : 28)
        let contentWidth = max(isUser ? 22 : 100, width - contentX - trailing)
        let title = displayTitle(for: item)
        let titleHeight: CGFloat = title.isEmpty ? 0 : 18
        let detailString = isCollapsed ? "" : visibleDetail(for: item)
        let detailHeight: CGFloat = detailString.isEmpty ? 0 : 16
        let displayed = displayBody(item, isExpanded: isExpanded)
        // Collapsed activity renders its preview in the header (routine) or
        // summary label (other collapsible kinds). Reserving a second hidden
        // body here was the reason compact rows still looked like large cards.
        var bodyHeight = isCollapsed
            ? 0
            : bodyAttributedText(for: item).boundingHeight(width: contentWidth)
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
        let showsStatus = (!isRoutineActivity && item.status != .completed)
            || item.status == .failed
            || item.status == .declined
            || (item.kind == .approval && item.status != .completed)
        let statusWidth: CGFloat = isActivity && titleHeight > 0 && showsStatus ? 68 : 0
        return Metrics(
            avatarX: isActivity ? (isQuietRoutineActivity ? 4 : 14) : 0,
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
        if maximumCharacters == 1 {
            let firstLine = item.body
                .prefix(previewSampleLength)
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
        let sample = item.body.prefix(previewSampleLength)
        let oneLine = sample
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

    static func bodyAttributedText(for item: TimelineItem) -> NSAttributedString {
        let font = bodyFont(for: item)
        guard item.kind.rendersMarkdown else {
            // Commands, diffs, and tool payloads are evidence. Rendering their
            // leading `+`, `-`, `#`, or `---` as Markdown would change what the
            // user sees and copies from the expanded activity row.
            return NSAttributedString(
                string: item.body,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
        return TranscriptMarkdownRenderer.attributedString(
            markdown: item.body,
            baseFont: font
        )
    }

    private static func bodyFont(for item: TimelineItem) -> NSFont {
        item.kind == .command
            ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
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
        isExpanded: Bool
    ) -> NSAttributedString {
        let title = displayTitle(for: item)
        guard item.kind.isRoutineActivity else {
            return NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }

        if isExpanded {
            return NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
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
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.86),
                ]
            )
        }

        let headline = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.86),
            ]
        )
        headline.append(
            NSAttributedString(
                string: "  ·  \(summary)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
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
        return protocolLabels.contains(normalized) ? "" : detail
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
        case .pending: NSColor.systemIndigo.withAlphaComponent(0.78)
        case .running: NSColor.systemBlue.withAlphaComponent(0.84)
        case .completed: .tertiaryLabelColor
        case .failed: .systemRed
        case .declined: .systemOrange
        }
    }

    private func statusTextColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .failed: .systemRed
        case .declined: .systemOrange
        case .running: .systemBlue
        case .pending: .systemIndigo
        case .completed: .secondaryLabelColor
        }
    }

    private func statusBackgroundColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .failed: NSColor.systemRed.withAlphaComponent(0.15)
        case .declined: NSColor.systemOrange.withAlphaComponent(0.15)
        case .running: NSColor.systemBlue.withAlphaComponent(0.10)
        case .pending: NSColor.systemGray.withAlphaComponent(0.10)
        case .completed: NSColor.systemGreen.withAlphaComponent(0.14)
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

    private func activityIconColor(for kind: TimelineItemKind) -> NSColor {
        switch kind {
        case .error: .systemRed
        case .approval: .systemOrange
        case .plan: .systemIndigo
        case .reasoning, .command, .fileChange, .tool, .system: .tertiaryLabelColor
        case .assistantMessage, .userMessage: .clear
        }
    }

    private func backgroundColor(for kind: TimelineItemKind) -> NSColor {
        switch kind {
        case .userMessage:
            NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        case .error:
            NSColor.systemRed.withAlphaComponent(0.09)
        case .approval:
            NSColor.systemOrange.withAlphaComponent(0.10)
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
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .linkColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.stringValue = link.detail ?? link.url.host ?? link.url.absoluteString
        detailLabel.font = .systemFont(ofSize: 10.5)
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
        statusLabel.font = .systemFont(ofSize: 12)
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
            || (kind.isRoutineActivity && (status == .failed || status == .declined))
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
