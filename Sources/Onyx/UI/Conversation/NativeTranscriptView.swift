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

final class TranscriptViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptItem")
    private static let pendingItemIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptPendingItem")

    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private var items: [TimelineItem] = []
    private var itemsRevision: UInt64?
    private var layoutState = TranscriptLayoutState()
    private var pendingResponse = TranscriptPendingResponse(isVisible: false, label: "Working")
    /// Expansion follows provider-stable timeline IDs, never collection
    /// indexes. Streaming and insertion can recycle cells while preserving a
    /// row's identity.
    private var expandedItemIDs = Set<String>()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        // Compact activity rows should read as one execution stream rather
        // than a stack of unrelated cards. A small shared gap visually groups
        // adjacent routine events without merging their identities or hiding
        // any detail from the disclosure control.
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 18, left: 24, bottom: 24, right: 24)
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
        let newPendingResponse = TranscriptPendingResponse.resolve(
            items: newItems,
            isAwaitingResponse: isAwaitingResponse,
            label: workingLabel
        )
        let pendingResponseChanged = newPendingResponse != pendingResponse
        pendingResponse = newPendingResponse
        let validExpandableIDs = Set(
            newItems.lazy
                .filter { $0.kind.isCollapsibleActivity }
                .map(\.id)
        )
        expandedItemIDs.formIntersection(validExpandableIDs)
        var planningInstrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        let update = TranscriptCollectionUpdate.plan(
            from: oldItems,
            to: newItems,
            oldRevision: itemsRevision,
            newRevision: newRevision,
            hint: changeHint,
            instrumentation: &planningInstrumentation
        )
        layoutState.prepare(for: update, newItems: newItems)
        items = newItems
        itemsRevision = newRevision

        if pendingResponseChanged {
            collectionView.reloadData()
        } else {
            switch update {
            case .unchanged:
                break
            case let .tailChange(index):
                reloadRows(IndexSet(integer: index))
            case let .rowChanges(indices):
                reloadRows(indices)
            case let .append(range):
                collectionView.insertItems(
                    at: Set(range.map { IndexPath(item: $0, section: 0) })
                )
            case .reloadAll:
                collectionView.reloadData()
            }
        }

        if shouldFollow || oldItems.isEmpty || pendingResponse.isVisible {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottom()
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count + (pendingResponse.isVisible ? 1 : 0)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        if pendingResponse.isVisible, indexPath.item == items.count {
            let item = collectionView.makeItem(
                withIdentifier: Self.pendingItemIdentifier,
                for: indexPath
            )
            (item as? TranscriptPendingCollectionItem)?.configure(label: pendingResponse.label)
            return item
        }

        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let transcriptItem = item as? TranscriptCollectionItem else { return item }
        let timelineItem = items[indexPath.item]
        transcriptItem.configure(
            with: timelineItem,
            isExpanded: isExpanded(timelineItem),
            onToggle: { [weak self] expanded in
                self?.setExpanded(expanded, for: timelineItem.id)
            }
        )
        return transcriptItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = readableWidth
        if pendingResponse.isVisible, indexPath.item == items.count {
            return NSSize(width: width, height: TranscriptPendingResponseView.rowHeight)
        }
        let item = items[indexPath.item]
        let expanded = isExpanded(item)
        return NSSize(
            width: width,
            height: layoutState.height(for: item, width: width, isExpanded: expanded) {
                TranscriptCellView.height(for: item, width: width, isExpanded: expanded)
            }
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let horizontal = max(22, (collectionView.bounds.width - readableWidth) / 2)
        return NSEdgeInsets(top: 18, left: horizontal, bottom: 24, right: horizontal)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if layoutState.readableWidthDidChange(to: readableWidth) {
            layout.invalidateLayout()
        }
    }

    private var readableWidth: CGFloat {
        // Wide windows should feel like a conversation canvas, not a narrow
        // phone column. This still stays comfortably readable while matching
        // the native Codex workspace's broader text measure.
        min(840, max(320, collectionView.bounds.width - 44))
    }

    private var isNearBottom: Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return documentView.bounds.height - visibleMaxY < 48
    }

    private func reloadRows(_ indices: IndexSet) {
        let indexPaths = Set(indices.map { IndexPath(item: $0, section: 0) })
        let context = NSCollectionViewLayoutInvalidationContext()
        context.invalidateItems(at: indexPaths)
        layout.invalidateLayout(with: context)
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

    private func scrollToBottom() {
        let itemCount = items.count + (pendingResponse.isVisible ? 1 : 0)
        guard itemCount > 0 else { return }
        collectionView.layoutSubtreeIfNeeded()
        let contentHeight = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        if contentHeight <= scrollView.contentView.bounds.height {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        collectionView.scrollToItems(
            at: [IndexPath(item: itemCount - 1, section: 0)],
            scrollPosition: .bottom
        )
    }
}

private final class TranscriptPendingResponseView: NSView {
    static let rowHeight: CGFloat = 38

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Working")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
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
        spinner.frame = NSRect(x: leading, y: 10, width: 16, height: 16)
        label.frame = NSRect(
            x: leading + 24,
            y: 8,
            width: max(0, bounds.width - leading - 24),
            height: 20
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

final class TranscriptCellView: NSView {
    static let maximumVisibleAttachments = TranscriptLayoutState.maximumVisibleAttachments
    static let maximumVisibleLinks = TranscriptLayoutState.maximumVisibleLinks

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
    let expansionControl = NSButton(title: "▸", target: nil, action: nil)
    private var attachmentViews: [TranscriptAttachmentView] = []
    private var linkViews: [TranscriptResourceLinkView] = []
    private var item: TimelineItem?
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
        bubbleBackground.layer?.cornerRadius = 11
        bubbleBackground.layer?.borderWidth = 1
        bubbleBackground.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
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
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 1
        bodyLabel.font = .systemFont(ofSize: 14.5, weight: .regular)
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
        expansionControl.title = "▸"
        expansionControl.font = .systemFont(ofSize: 14, weight: .semibold)
        expansionControl.alignment = .right
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

        titleLabel.attributedStringValue = Self.headerAttributedText(for: item, isExpanded: self.isExpanded)
        summaryLabel.stringValue = Self.compactSummary(for: item)
        bodyLabel.stringValue = item.body
        detailLabel.stringValue = detailText(for: item, collapsed: self.isExpandable && !self.isExpanded)
        statusLabel.stringValue = statusText(for: item.status)
        avatar.stringValue = avatarGlyph(for: item.kind)
        avatar.textColor = activityIconColor(for: item.kind)
        statusLabel.textColor = statusTextColor(for: item.status)

        switch item.kind {
        case .command:
            bodyLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        default:
            bodyLabel.font = .systemFont(ofSize: 14.5, weight: .regular)
        }

        let isProminentActivity = item.kind.isProminentActivity
        let isExpandedRoutineActivity = item.kind.isRoutineActivity && self.isExpanded
        layer?.cornerRadius = isProminentActivity ? 10 : (isExpandedRoutineActivity ? 8 : 0)
        layer?.borderWidth = isProminentActivity ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        layer?.backgroundColor = if isProminentActivity {
            backgroundColor(for: item.kind).cgColor
        } else if isExpandedRoutineActivity {
            NSColor.controlBackgroundColor.withAlphaComponent(0.28).cgColor
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
        isExpandable = false
        isExpanded = true
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
            rebuildMediaViews()
        } else {
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
        let isProminentActivity = item.kind.isProminentActivity
        let isExpandedRoutineActivity = item.kind.isRoutineActivity && isExpanded
        layer?.cornerRadius = isProminentActivity ? 10 : (isExpandedRoutineActivity ? 8 : 0)
        layer?.borderWidth = isProminentActivity ? 1 : 0
        layer?.backgroundColor = if isProminentActivity {
            backgroundColor(for: item.kind).cgColor
        } else if isExpandedRoutineActivity {
            NSColor.controlBackgroundColor.withAlphaComponent(0.28).cgColor
        } else {
            NSColor.clear.cgColor
        }
        titleLabel.attributedStringValue = Self.headerAttributedText(for: item, isExpanded: isExpanded)
        summaryLabel.isHidden = !collapsed || item.body.isEmpty
        bodyLabel.isHidden = collapsed || item.body.isEmpty
        detailLabel.stringValue = detailText(for: item, collapsed: collapsed)
        expansionControl.isHidden = !isExpandable
        expansionControl.title = isExpanded ? "⌃" : "▸"
        expansionControl.setAccessibilityLabel(
            "\(isExpanded ? "Collapse" : "Expand") \(displayTitle(for: item)) details"
        )
        expansionControl.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        expansionControl.setAccessibilityHelp(
            isExpanded
                ? "Hides verbose activity output"
                : "Shows the complete tool output, attachments, and links"
        )
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
            return expansionControl
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let metrics = Self.metrics(for: item, width: bounds.width, isExpanded: isExpanded)
        if item.kind == .userMessage {
            let horizontalInset: CGFloat = 15
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
            width: max(0, metrics.contentWidth - metrics.statusWidth - disclosureWidth - 8),
            height: metrics.titleHeight
        )
        statusLabel.frame = NSRect(
            x: metrics.contentX + max(0, metrics.contentWidth - metrics.statusWidth - disclosureWidth),
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
            x: max(0, bounds.width - disclosureWidth),
            y: max(0, headerTop - metrics.headerHeight),
            width: disclosureWidth,
            height: metrics.headerHeight
        )
        avatar.isHidden = !item.kind.isActivity
        titleLabel.isHidden = metrics.titleHeight == 0
        summaryLabel.isHidden = !metrics.isCollapsed || item.body.isEmpty
        bodyLabel.isHidden = metrics.isCollapsed || item.body.isEmpty
        detailLabel.isHidden = metrics.detailHeight == 0
        statusLabel.isHidden = !item.kind.isActivity || metrics.titleHeight == 0
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
        let horizontalInset: CGFloat = isUser ? 15 : (isActivity ? (isRoutineActivity ? 5 : 14) : 0)
        let userBubbleMaximum = min(560, width * 0.78)
        let preferredUserBubbleWidth = item.attachments.isEmpty && item.links.isEmpty
            ? item.body.preferredBubbleWidth(fontSize: 14.5)
            : max(360, width * 0.56)
        let userBubbleWidth = min(userBubbleMaximum, max(132, preferredUserBubbleWidth))
        let contentX: CGFloat = isUser
            ? max(0, width - userBubbleWidth) + horizontalInset
            : (isActivity ? (isRoutineActivity ? 22 : 34) + horizontalInset : 28)
        let trailing: CGFloat = isUser ? horizontalInset : (isActivity ? horizontalInset : 28)
        let contentWidth = max(100, width - contentX - trailing)
        let title = displayTitle(for: item)
        let titleHeight: CGFloat = title.isEmpty ? 0 : 18
        let detailString = isCollapsed ? "" : visibleDetail(for: item)
        let detailHeight: CGFloat = detailString.isEmpty ? 0 : 16
        let font = item.kind == .command
            ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : NSFont.systemFont(ofSize: 14.5)
        let displayed = displayBody(item, isExpanded: isExpanded)
        // Collapsed activity renders its preview in the header (routine) or
        // summary label (other collapsible kinds). Reserving a second hidden
        // body here was the reason compact rows still looked like large cards.
        var bodyHeight = isCollapsed ? 0 : displayed.boundingHeight(width: contentWidth, font: font)
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
        if isRoutineActivity && isCollapsed {
            top = 5
            bottom = 5
        } else {
            top = isActivity || isUser ? (isCollapsed ? 10 : 13) : 8
            bottom = isActivity || isUser ? (isCollapsed ? 9 : 12) : 10
        }
        let showsStatus = item.status != .completed
        let statusWidth: CGFloat = isActivity && titleHeight > 0 && showsStatus ? 68 : 0
        return Metrics(
            avatarX: isActivity ? (isRoutineActivity ? 4 : 14) : 0,
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
        guard maximumCharacters > 1 else {
            return String(item.body.prefix(max(0, maximumCharacters)))
        }
        // Do not scan a multi-megabyte tool payload just to find a preview.
        // The first few kilobytes are enough to produce a useful one-line
        // summary and keep streaming updates cheap on the main thread.
        let sample = item.body.prefix(maximumCharacters * 4)
        let oneLine = sample
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard oneLine.count > maximumCharacters else { return oneLine }
        return String(oneLine.prefix(maximumCharacters - 1)) + "…"
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
        guard item.kind.isRoutineActivity, !isExpanded else {
            return NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
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
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }

        let headline = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        headline.append(
            NSAttributedString(
                string: "  ·  \(summary)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
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

    private func statusTextColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .failed: .systemRed
        case .declined: .systemOrange
        case .running, .pending, .completed: .secondaryLabelColor
        }
    }

    private func statusBackgroundColor(for status: TimelineItemStatus) -> NSColor {
        switch status {
        case .failed: NSColor.systemRed.withAlphaComponent(0.15)
        case .declined: NSColor.systemOrange.withAlphaComponent(0.15)
        case .running: NSColor.systemBlue.withAlphaComponent(0.14)
        case .pending: NSColor.systemGray.withAlphaComponent(0.14)
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
            NSColor.controlBackgroundColor.withAlphaComponent(0.96)
        case .error:
            NSColor.systemRed.withAlphaComponent(0.09)
        case .approval:
            NSColor.systemOrange.withAlphaComponent(0.10)
        case _ where kind.isActivity:
            NSColor.controlBackgroundColor.withAlphaComponent(0.72)
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
    var isActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool, .plan, .approval, .system, .error:
            true
        case .userMessage, .assistantMessage:
            false
        }
    }

    /// Verbose implementation activity is opt-in detail. Plans, approvals,
    /// and failures stay visible because they communicate an actionable state
    /// rather than incidental tool chatter.
    var isCollapsibleActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool:
            true
        case .plan, .approval, .error, .system, .userMessage, .assistantMessage:
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

    /// Plans and actionable states retain a bounded surface so they cannot be
    /// mistaken for incidental execution chatter.
    var isProminentActivity: Bool {
        switch self {
        case .plan, .approval, .error, .system:
            true
        case .reasoning, .command, .fileChange, .tool, .userMessage, .assistantMessage:
            false
        }
    }

    var defaultExpanded: Bool {
        !isCollapsibleActivity
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
        return ceil(measured + 30)
    }
}
