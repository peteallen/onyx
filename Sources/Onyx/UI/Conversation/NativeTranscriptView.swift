import AppKit
import ImageIO
import SwiftUI

struct NativeTranscriptView: NSViewControllerRepresentable {
    let items: [TimelineItem]
    var revision: UInt64? = nil
    var changeHint: TranscriptCollectionUpdate.Hint? = nil

    func makeNSViewController(context: Context) -> TranscriptViewController {
        TranscriptViewController()
    }

    func updateNSViewController(_ controller: TranscriptViewController, context: Context) {
        controller.update(items: items, revision: revision, changeHint: changeHint)
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
        let visibleAttachmentCount: Int
        let links: [TimelineResourceLink]

        init(item: TimelineItem) {
            kind = item.kind.rawValue
            title = item.title
            body = item.body
            detail = item.detail
            visibleAttachmentCount = min(
                TranscriptLayoutState.maximumVisibleAttachments,
                item.attachments.count
            )
            links = Array(item.links.prefix(TranscriptLayoutState.maximumVisibleLinks))
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
        let revision = LayoutRevision(item: item)
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
        var currentRevisions: [String: LayoutRevision] = [:]
        currentRevisions.reserveCapacity(items.count)
        for item in items {
            let revision = LayoutRevision(item: item)
            if currentRevisions.updateValue(revision, forKey: item.id) != nil {
                // Timeline identities are expected to be unique. If a provider
                // violates that contract, sharing one cached height is unsafe.
                cachedHeightsByItemID.removeAll(keepingCapacity: true)
                return
            }
        }

        cachedHeightsByItemID = cachedHeightsByItemID.filter { itemID, cached in
            currentRevisions[itemID] == cached.revision
        }
    }
}

final class TranscriptViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("OnyxTranscriptItem")

    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let layout = NSCollectionViewFlowLayout()
    private var items: [TimelineItem] = []
    private var itemsRevision: UInt64?
    private var layoutState = TranscriptLayoutState()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)
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
        layoutState.prepare(for: update, newItems: newItems)
        items = newItems
        itemsRevision = newRevision

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

        if shouldFollow || oldItems.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottom()
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let transcriptItem = item as? TranscriptCollectionItem else { return item }
        transcriptItem.configure(with: items[indexPath.item])
        return transcriptItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let width = readableWidth
        return NSSize(
            width: width,
            height: layoutState.height(for: items[indexPath.item], width: width) {
                TranscriptCellView.height(for: items[indexPath.item], width: width)
            }
        )
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        insetForSectionAt section: Int
    ) -> NSEdgeInsets {
        let horizontal = max(22, (collectionView.bounds.width - readableWidth) / 2)
        return NSEdgeInsets(top: 24, left: horizontal, bottom: 28, right: horizontal)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if layoutState.readableWidthDidChange(to: readableWidth) {
            layout.invalidateLayout()
        }
    }

    private var readableWidth: CGFloat {
        min(760, max(360, collectionView.bounds.width - 44))
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

    private func scrollToBottom() {
        guard !items.isEmpty else { return }
        collectionView.scrollToItems(
            at: [IndexPath(item: items.count - 1, section: 0)],
            scrollPosition: .bottom
        )
    }
}

private final class TranscriptCollectionItem: NSCollectionViewItem {
    override func loadView() {
        view = TranscriptCellView()
    }

    func configure(with item: TimelineItem) {
        (view as? TranscriptCellView)?.configure(with: item)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? TranscriptCellView)?.prepareForReuse()
    }
}

final class TranscriptCellView: NSView {
    static let maximumVisibleAttachments = TranscriptLayoutState.maximumVisibleAttachments
    static let maximumVisibleLinks = TranscriptLayoutState.maximumVisibleLinks

    private let avatar = NSTextField(labelWithString: "◆")
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var attachmentViews: [TranscriptAttachmentView] = []
    private var linkViews: [TranscriptResourceLinkView] = []
    private var item: TimelineItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(avatar)
        addSubview(titleLabel)
        addSubview(bodyLabel)
        addSubview(detailLabel)

        avatar.font = .systemFont(ofSize: 12, weight: .semibold)
        avatar.textColor = NSColor.systemPurple
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 14.5, weight: .regular)
        bodyLabel.textColor = .labelColor
        bodyLabel.isSelectable = true
        bodyLabel.allowsEditingTextAttributes = true
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: TimelineItem) {
        attachmentViews.forEach { view in
            view.cancelLoading()
            view.removeFromSuperview()
        }
        attachmentViews.removeAll(keepingCapacity: true)
        linkViews.forEach { $0.removeFromSuperview() }
        linkViews.removeAll(keepingCapacity: true)
        self.item = item
        titleLabel.stringValue = item.title ?? ""
        bodyLabel.stringValue = displayBody(item)
        detailLabel.stringValue = item.detail ?? ""
        avatar.stringValue = avatarGlyph(for: item.kind)

        switch item.kind {
        case .command:
            bodyLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        default:
            bodyLabel.font = .systemFont(ofSize: 14.5, weight: .regular)
        }

        layer?.cornerRadius = item.kind == .assistantMessage ? 0 : 12
        layer?.borderWidth = item.kind.isActivity ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        layer?.backgroundColor = backgroundColor(for: item.kind).cgColor

        let visibleAttachments = Array(item.attachments.prefix(Self.maximumVisibleAttachments))
        attachmentViews = visibleAttachments.map { attachment in
            let view = TranscriptAttachmentView(attachment: attachment)
            addSubview(view)
            return view
        }
        let visibleLinks = Array(item.links.prefix(Self.maximumVisibleLinks))
        linkViews = visibleLinks.map { link in
            let view = TranscriptResourceLinkView(link: link)
            addSubview(view)
            return view
        }
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        attachmentViews.forEach { view in
            view.cancelLoading()
            view.removeFromSuperview()
        }
        attachmentViews.removeAll()
        linkViews.forEach { $0.removeFromSuperview() }
        linkViews.removeAll()
        item = nil
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let metrics = Self.metrics(for: item, width: bounds.width)
        avatar.frame = NSRect(x: metrics.avatarX, y: bounds.height - 22, width: 20, height: 18)
        titleLabel.frame = NSRect(
            x: metrics.contentX,
            y: bounds.height - metrics.top - metrics.titleHeight,
            width: metrics.contentWidth,
            height: metrics.titleHeight
        )
        let bodyTop = bounds.height - metrics.top - metrics.titleHeight - metrics.titleGap
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
        }
        detailLabel.frame = NSRect(
            x: metrics.contentX,
            y: metrics.bottom,
            width: metrics.contentWidth,
            height: metrics.detailHeight
        )
        avatar.isHidden = item.kind == .userMessage
        titleLabel.isHidden = metrics.titleHeight == 0
        bodyLabel.isHidden = item.body.isEmpty
        detailLabel.isHidden = metrics.detailHeight == 0
    }

    static func height(for item: TimelineItem, width: CGFloat) -> CGFloat {
        let metrics = metrics(for: item, width: width)
        return metrics.top + metrics.titleHeight + metrics.titleGap
            + metrics.bodyHeight + metrics.attachmentGap + metrics.attachmentsHeight
            + metrics.linkGap + metrics.linksHeight
            + metrics.detailGap + metrics.detailHeight + metrics.bottom
    }

    static func metrics(for item: TimelineItem, width: CGFloat) -> Metrics {
        let isUser = item.kind == .userMessage
        let isActivity = item.kind.isActivity
        let horizontalInset: CGFloat = isUser ? 18 : (isActivity ? 14 : 0)
        let contentX: CGFloat = isUser ? max(88, width * 0.13) + horizontalInset : 34 + horizontalInset
        let trailing: CGFloat = horizontalInset
        let contentWidth = max(180, width - contentX - trailing)
        let titleHeight: CGFloat = (item.title?.isEmpty == false) ? 18 : 0
        let detailHeight: CGFloat = (item.detail?.isEmpty == false) ? 16 : 0
        let font = item.kind == .command
            ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : NSFont.systemFont(ofSize: 14.5)
        let displayed = displayBody(item)
        var bodyHeight = displayed.boundingHeight(width: contentWidth, font: font)
        if displayed.isEmpty { bodyHeight = 0 }
        if isActivity { bodyHeight = min(bodyHeight, 188) }
        let attachmentCount = min(maximumVisibleAttachments, item.attachments.count)
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
        let linkCount = min(Self.maximumVisibleLinks, item.links.count)
        let linkHeight: CGFloat = linkCount > 0 ? 34 : 0
        let linksHeight = CGFloat(linkCount) * linkHeight
            + CGFloat(max(0, linkCount - 1)) * linkSpacing
        let linkGap: CGFloat = linkCount > 0
            && (bodyHeight > 0 || attachmentsHeight > 0) ? 9 : 0
        let contentHeightBeforeDetail = bodyHeight + attachmentGap + attachmentsHeight
            + linkGap + linksHeight

        return Metrics(
            avatarX: isActivity ? 14 : 0,
            contentX: contentX,
            contentWidth: contentWidth,
            top: isActivity || isUser ? 13 : 8,
            titleHeight: titleHeight,
            titleGap: titleHeight > 0 && bodyHeight > 0 ? 5 : 0,
            bodyHeight: bodyHeight,
            attachmentGap: attachmentGap,
            attachmentColumns: attachmentColumns,
            attachmentWidth: attachmentWidth,
            attachmentHeight: attachmentHeight,
            attachmentsHeight: attachmentsHeight,
            linkGap: linkGap,
            linkHeight: linkHeight,
            linksHeight: linksHeight,
            detailGap: detailHeight > 0 && contentHeightBeforeDetail > 0 ? 7 : 0,
            detailHeight: detailHeight,
            bottom: isActivity || isUser ? 12 : 10
        )
    }

    private static func displayBody(_ item: TimelineItem) -> String {
        guard item.kind.isActivity, item.body.count > 4_000 else { return item.body }
        return String(item.body.prefix(4_000)) + "\n…"
    }

    private func displayBody(_ item: TimelineItem) -> String {
        Self.displayBody(item)
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

    private func backgroundColor(for kind: TimelineItemKind) -> NSColor {
        switch kind {
        case .userMessage:
            NSColor.systemPurple.withAlphaComponent(0.11)
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

private extension TimelineItemKind {
    var isActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool, .plan, .approval, .system, .error:
            true
        case .userMessage, .assistantMessage:
            false
        }
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
}
