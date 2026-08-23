import AppKit
import SwiftUI
import XCTest
@testable import Onyx

final class TranscriptLayoutPerformanceTests: XCTestCase {
    @MainActor
    func testHostingViewSurvivesRepeatedRowChangesDuringLayout() throws {
        let fixture = TranscriptLayoutMutationFixture()
        let hostingView = NSHostingView(
            rootView: TranscriptLayoutMutationHarness(fixture: fixture)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // The test owns this window through ARC. Letting `close()` also
        // release it produces a false post-test over-release in XCTest's
        // object-lifetime checker.
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout(width: CGFloat = 720) {
            window.setContentSize(NSSize(width: width, height: 480))
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 1)

        // Exercise the reloadData paths that insert and remove the inline
        // pending row around the provider's first visible token.
        fixture.isAwaitingResponse = true
        layout()
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 2)

        fixture.appendAssistant(body: "", status: .running)
        layout(width: 520)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 3)

        fixture.mutateTail(body: "First visible token", status: .running)
        layout(width: 900)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 2)

        for step in 1...40 {
            fixture.advance(step: step)
            layout(width: step.isMultiple(of: 2) ? 520 : 900)
        }
        XCTAssertTrue(fixture.snapshot.items[1].body.contains("update 40"))

        fixture.isAwaitingResponse = false
        fixture.mutateTail(body: "Streaming complete", status: .completed)
        layout()

        // Exercise both ways activity topology changes: appending the second
        // completed activity creates a group, and completing a running tail
        // turns an existing row into a grouped child.
        fixture.appendActivity(id: "group-one-command", kind: .command, status: .completed)
        layout(width: 520)
        fixture.appendActivity(id: "group-one-tool", kind: .tool, status: .completed)
        layout(width: 900)

        fixture.appendAssistant(body: "Activity boundary", status: .completed)
        layout()
        fixture.appendActivity(id: "group-two-command", kind: .command, status: .completed)
        layout(width: 520)
        fixture.appendActivity(id: "group-two-tool", kind: .tool, status: .running)
        layout(width: 900)
        fixture.mutateTail(body: "Tool finished", status: .completed)
        layout()

        let contentSize = collectionView.collectionViewLayout?.collectionViewContentSize ?? .zero
        XCTAssertTrue(contentSize.width.isFinite)
        XCTAssertTrue(contentSize.height.isFinite)
        XCTAssertGreaterThanOrEqual(contentSize.width, 0)
        XCTAssertGreaterThanOrEqual(contentSize.height, 0)
        XCTAssertGreaterThan(fixture.snapshot.revision, 41)
        XCTAssertEqual(fixture.snapshot.items[1].body, "Streaming complete")

        // Drain deferred follow-scroll work before releasing the AppKit host.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    func testFlowMetricsAlwaysLeaveStrictLayoutWidth() {
        for collectionWidth: CGFloat in [0, 0.5, 1, 2, 48, 320, 520, 720, 900, 1_200] {
            let metrics = TranscriptFlowMetrics(collectionWidth: collectionWidth)

            XCTAssertTrue(metrics.itemWidth.isFinite)
            XCTAssertTrue(metrics.horizontalInset.isFinite)
            XCTAssertGreaterThanOrEqual(metrics.itemWidth, 0)
            XCTAssertGreaterThanOrEqual(metrics.horizontalInset, 0)
            if collectionWidth > TranscriptFlowMetrics.layoutSafetyWidth {
                XCTAssertLessThan(
                    metrics.itemWidth + metrics.horizontalInset * 2,
                    collectionWidth
                )
            } else {
                XCTAssertEqual(metrics.itemWidth, 0)
                XCTAssertEqual(metrics.horizontalInset, 0)
            }
        }
    }

    @MainActor
    func testExpansionIsPartOfHeightCacheAndInvalidatesOnlyTheToggledRow() {
        let item = TimelineItem(
            id: "tool-cache",
            kind: .tool,
            title: "Search",
            body: String(repeating: "verbose tool output ", count: 80),
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        var state = TranscriptLayoutState()

        _ = state.height(for: item, width: 640, isExpanded: false) { 42 }
        _ = state.height(for: item, width: 640, isExpanded: false) { 99 }
        XCTAssertEqual(state.instrumentation.measurementCount, 1)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 1)

        _ = state.height(for: item, width: 640, isExpanded: true) { 84 }
        XCTAssertEqual(state.instrumentation.measurementCount, 2)

        state.invalidate(itemID: item.id)
        _ = state.height(for: item, width: 640, isExpanded: true) { 126 }
        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 1)
    }

    @MainActor
    func testExpansionStateDoesNotTruncateReadableActivityOutput() {
        let item = TimelineItem(
            id: "long-tool",
            kind: .command,
            title: "Run command",
            body: String(repeating: "line with useful output\n", count: 80),
            status: .completed,
            timestamp: .now,
            detail: nil
        )

        let collapsed = TranscriptCellView.metrics(for: item, width: 640, isExpanded: false)
        let expanded = TranscriptCellView.metrics(for: item, width: 640, isExpanded: true)

        XCTAssertTrue(collapsed.isCollapsed)
        XCTAssertFalse(expanded.isCollapsed)
        XCTAssertLessThan(collapsed.bodyHeight + collapsed.summaryHeight, expanded.bodyHeight)
        XCTAssertGreaterThan(expanded.bodyHeight, 188, "Expanded activity output must remain readable")
    }

    @MainActor
    func testApprovalsAndErrorsRemainVisibleWhilePlansUseCompactProgress() {
        let body = "Actionable status"
        for kind in [TimelineItemKind.approval, .error] {
            let item = TimelineItem(
                id: "always-visible-\(kind.rawValue)",
                kind: kind,
                title: kind.rawValue,
                body: body,
                status: .completed,
                timestamp: .now,
                detail: nil
            )
            XCTAssertFalse(kind.isCollapsibleActivity)
            XCTAssertTrue(kind.defaultExpanded)
            XCTAssertEqual(
                TranscriptCellView.height(for: item, width: 640, isExpanded: false),
                TranscriptCellView.height(for: item, width: 640, isExpanded: true),
                accuracy: 0.5
            )
        }

        let plan = TimelineItem(
            id: "compact-plan",
            kind: .plan,
            title: "Plan",
            body: "[x] Inspect\n[~] Simplify\n[ ] Verify",
            status: .running,
            timestamp: .now,
            detail: nil
        )
        XCTAssertTrue(plan.kind.isCollapsibleActivity)
        XCTAssertFalse(plan.kind.defaultExpanded)
        XCTAssertLessThan(
            TranscriptCellView.height(for: plan, width: 640, isExpanded: false),
            TranscriptCellView.height(for: plan, width: 640, isExpanded: true)
        )
    }

    func testUnchangedSnapshotReusesEveryMeasuredHeight() {
        let items = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
        ]
        var state = TranscriptLayoutState()
        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: items, to: items)
        XCTAssertEqual(update, .unchanged)
        state.prepare(for: update, newItems: items)
        _ = measure(items, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 3)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 0)
    }

    func testTailStreamingInvalidatesAndMeasuresOnlyTheTailRow() {
        let oldItems = [
            makeItem(id: "one", body: "Stable one"),
            makeItem(id: "two", body: "Stable two"),
            makeItem(id: "stream", body: "Partial"),
        ]
        var newItems = oldItems
        newItems[2].body = "Partial response with the next streamed delta"
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .tailChange(2))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 4)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 1)
    }

    func testAppendMeasuresOnlyNewRows() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
        ]
        let newItems = oldItems + [makeItem(id: "three", body: "Third")]
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .append(2..<3))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 0)
    }

    @MainActor
    func testStatusChangeCombinedWithStructuralReloadDoesNotReuseStaleHeight() {
        let running = TimelineItem(
            id: "live-tool",
            kind: .tool,
            title: "Search",
            body: "Result",
            status: .running,
            timestamp: .now,
            detail: nil
        )
        var completed = running
        completed.status = .completed
        let newItems = [completed, makeItem(id: "assistant", body: "Finished")]
        var state = TranscriptLayoutState()

        let runningHeight = state.height(
            for: running,
            width: 640,
            isExpanded: false
        ) {
            TranscriptCellView.height(for: running, width: 640, isExpanded: false)
        }
        let update = TranscriptCollectionUpdate.plan(from: [running], to: newItems)
        XCTAssertEqual(update, .reloadAll)
        state.prepare(for: update, newItems: newItems)

        let expectedCompletedHeight = TranscriptCellView.height(
            for: completed,
            width: 640,
            isExpanded: false
        )
        let renderedCompletedHeight = state.height(
            for: completed,
            width: 640,
            isExpanded: false
        ) {
            expectedCompletedHeight
        }

        XCTAssertNotEqual(runningHeight, expectedCompletedHeight)
        XCTAssertEqual(renderedCompletedHeight, expectedCompletedHeight)
        XCTAssertEqual(state.instrumentation.measurementCount, 2)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 0)
    }

    func testSameIdentityEditsInvalidateOnlyTheirRows() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
            makeItem(id: "four", body: "Fourth"),
        ]
        var newItems = oldItems
        newItems[0].body += " changed"
        newItems[2].detail = "Changed detail"
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        _ = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: newItems)
        XCTAssertEqual(update, .rowChanges(IndexSet([0, 2])))
        state.prepare(for: update, newItems: newItems)
        _ = measure(newItems, width: 640, state: &state)

        XCTAssertEqual(state.instrumentation.measurementCount, 6)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 2)
        XCTAssertEqual(state.instrumentation.invalidatedRowCount, 2)
    }

    func testReorderUsesSafeReloadWhileRetainingIdentityCorrectHeights() {
        let oldItems = [
            makeItem(id: "short", body: "A"),
            makeItem(id: "medium", body: "A medium body"),
            makeItem(id: "long", body: "A substantially longer body for this row"),
        ]
        let reordered = [oldItems[2], oldItems[0], oldItems[1]]
        var state = TranscriptLayoutState()
        _ = state.readableWidthDidChange(to: 640)
        let originalHeights = measure(oldItems, width: 640, state: &state)

        let update = TranscriptCollectionUpdate.plan(from: oldItems, to: reordered)
        XCTAssertEqual(update, .reloadAll)
        state.prepare(for: update, newItems: reordered)
        let reorderedHeights = measure(reordered, width: 640, state: &state)

        XCTAssertEqual(reorderedHeights, [originalHeights[2], originalHeights[0], originalHeights[1]])
        XCTAssertEqual(state.instrumentation.measurementCount, 3)
        XCTAssertEqual(state.instrumentation.cacheHitCount, 3)
        XCTAssertEqual(
            TranscriptCollectionUpdate.plan(from: oldItems, to: Array(oldItems.dropLast())),
            .reloadAll
        )

        var middleInsertion = oldItems
        middleInsertion.insert(makeItem(id: "inserted", body: "Inserted"), at: 1)
        XCTAssertEqual(
            TranscriptCollectionUpdate.plan(from: oldItems, to: middleInsertion),
            .reloadAll
        )
    }

    func testOnlyARealReadableWidthChangeGloballyInvalidatesHeights() {
        let items = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
        ]
        var state = TranscriptLayoutState()

        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)
        XCTAssertFalse(state.readableWidthDidChange(to: 640))
        _ = measure(items, width: 640, state: &state)
        XCTAssertEqual(state.instrumentation.measurementCount, 2)
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 0)

        XCTAssertTrue(state.readableWidthDidChange(to: 600))
        _ = measure(items, width: 600, state: &state)
        XCTAssertEqual(state.instrumentation.measurementCount, 4)
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 1)
        XCTAssertFalse(state.readableWidthDidChange(to: 600))
        XCTAssertEqual(state.instrumentation.globalInvalidationCount, 1)
    }

    func testRevisionBoundTailHintsKeepLargeHistoryPlanningBounded() {
        var oldItems = (0..<20_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        var revision: UInt64 = 10

        for delta in 0..<100 {
            var newItems = oldItems
            newItems[newItems.count - 1].body += " delta-\(delta)"
            let nextRevision = revision + 1
            let update = TranscriptCollectionUpdate.plan(
                from: oldItems,
                to: newItems,
                oldRevision: revision,
                newRevision: nextRevision,
                hint: .rowsChanged(
                    indices: IndexSet(integer: newItems.count - 1),
                    fromRevision: revision,
                    toRevision: nextRevision
                ),
                instrumentation: &instrumentation
            )

            XCTAssertEqual(update, .tailChange(newItems.count - 1))
            oldItems = newItems
            revision = nextRevision
        }

        XCTAssertEqual(instrumentation.inspectedItemCount, 100)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 100)
    }

    func testPresentationSnapshotProducesAtomicTailHintsForStreaming() {
        let items = (0..<20_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        var snapshot = TranscriptPresentationSnapshot(items: items, revision: 40)
        let oldSnapshot = snapshot
        let tailIndex = items.count - 1

        snapshot.mutateRows(IndexSet(integer: tailIndex)) { updated in
            updated[tailIndex].body += " streamed"
        }

        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        let update = TranscriptCollectionUpdate.plan(
            from: oldSnapshot.items,
            to: snapshot.items,
            oldRevision: oldSnapshot.revision,
            newRevision: snapshot.revision,
            hint: snapshot.changeHint,
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .tailChange(tailIndex))
        XCTAssertEqual(instrumentation.inspectedItemCount, 1)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 1)
    }

    func testPresentationSnapshotCoalescesAppendHintsWithoutRescanningHistory() {
        let items = (0..<20_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        var snapshot = TranscriptPresentationSnapshot(items: items, revision: 40)
        let original = snapshot

        snapshot.append(makeItem(id: "appended-one", body: "First append"))
        let intermediate = snapshot
        snapshot.append(makeItem(id: "appended-two", body: "Second append"))

        for rendered in [original, intermediate] {
            var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
            let update = TranscriptCollectionUpdate.plan(
                from: rendered.items,
                to: snapshot.items,
                oldRevision: rendered.revision,
                newRevision: snapshot.revision,
                hint: snapshot.changeHint,
                instrumentation: &instrumentation
            )

            XCTAssertEqual(update, .append(rendered.items.count..<snapshot.items.count))
            XCTAssertEqual(instrumentation.inspectedItemCount, 0)
            XCTAssertEqual(instrumentation.hintedUpdateCount, 1)
        }
    }

    func testSkippedSnapshotCannotApplyAStaleRowHint() {
        let items = (0..<2_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        let rendered = TranscriptPresentationSnapshot(items: items, revision: 10)
        var skipped = rendered
        skipped.mutateRows(IndexSet(integer: items.count - 1)) { updated in
            updated[updated.count - 1].body += " first"
        }
        var latest = skipped
        latest.mutateRows(IndexSet(integer: items.count - 1)) { updated in
            updated[updated.count - 1].body += " second"
        }

        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()
        let update = TranscriptCollectionUpdate.plan(
            from: rendered.items,
            to: latest.items,
            oldRevision: rendered.revision,
            newRevision: latest.revision,
            hint: latest.changeHint,
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .tailChange(items.count - 1))
        XCTAssertEqual(instrumentation.hintedUpdateCount, 0)
        XCTAssertEqual(
            instrumentation.inspectedItemCount,
            items.count,
            "A revision gap must fall back to structural validation instead of trusting a stale hint"
        )
    }

    func testRepeatedSwiftUIUpdateAtSameRevisionDoesNotRescanHistory() {
        let items = (0..<20_000).map { index in
            makeItem(id: "item-\(index)", body: "Stable \(index)")
        }
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()

        let update = TranscriptCollectionUpdate.plan(
            from: items,
            to: items,
            oldRevision: 25,
            newRevision: 25,
            hint: .rowsChanged(
                indices: IndexSet(integer: items.count - 1),
                fromRevision: 24,
                toRevision: 25
            ),
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .unchanged)
        XCTAssertEqual(instrumentation.inspectedItemCount, 0)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 0)
    }

    func testHintWithBrokenRevisionContinuityFallsBackToStructuralPlanning() {
        let oldItems = [
            makeItem(id: "one", body: "First"),
            makeItem(id: "two", body: "Second"),
            makeItem(id: "three", body: "Third"),
        ]
        let reordered = [oldItems[2], oldItems[1], oldItems[0]]
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()

        let update = TranscriptCollectionUpdate.plan(
            from: oldItems,
            to: reordered,
            oldRevision: 4,
            newRevision: 5,
            hint: .rowsChanged(
                indices: IndexSet(integer: 2),
                fromRevision: 3,
                toRevision: 5
            ),
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .reloadAll)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 0)
    }

    private func measure(
        _ items: [TimelineItem],
        width: CGFloat,
        state: inout TranscriptLayoutState
    ) -> [CGFloat] {
        var heights: [CGFloat] = []
        heights.reserveCapacity(items.count)
        for item in items {
            heights.append(
                state.height(for: item, width: width) {
                    CGFloat(item.body.utf8.count) + width / 100
                }
            )
        }
        return heights
    }

    private func makeItem(id: String, body: String) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 1_000),
            detail: nil
        )
    }
}

@MainActor
private final class TranscriptLayoutMutationFixture: ObservableObject {
    @Published var isAwaitingResponse = false
    @Published var snapshot = TranscriptPresentationSnapshot(
        items: [
            TimelineItem(
                id: "hosting-layout-user",
                kind: .userMessage,
                title: nil,
                body: "Keep the transcript responsive.",
                status: .completed,
                timestamp: Date(timeIntervalSince1970: 1_000),
                detail: nil
            ),
        ],
        revision: 1
    )

    func advance(step: Int) {
        mutateTail(
            body: String(repeating: "streamed update \(step) ", count: 1 + step % 6),
            status: step.isMultiple(of: 4) ? .completed : .running
        )
    }

    func appendAssistant(body: String, status: TimelineItemStatus) {
        var next = snapshot
        next.append(
            TimelineItem(
                id: "hosting-layout-assistant-\(next.items.count)",
                kind: .assistantMessage,
                title: nil,
                body: body,
                status: status,
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(next.items.count)),
                detail: nil
            )
        )
        snapshot = next
    }

    func appendActivity(
        id: String,
        kind: TimelineItemKind,
        status: TimelineItemStatus
    ) {
        var next = snapshot
        next.append(
            TimelineItem(
                id: id,
                kind: kind,
                title: kind == .command ? "Run command" : "Use tool",
                body: status == .running ? "Working" : "Finished",
                status: status,
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(next.items.count)),
                detail: nil
            )
        )
        snapshot = next
    }

    func mutateTail(body: String, status: TimelineItemStatus) {
        var next = snapshot
        let index = next.items.count - 1
        next.mutateRows(IndexSet(integer: index)) { items in
            items[index].body = body
            items[index].status = status
        }
        snapshot = next
    }
}

private struct TranscriptLayoutMutationHarness: View {
    @ObservedObject var fixture: TranscriptLayoutMutationFixture

    var body: some View {
        NativeTranscriptView(
            items: fixture.snapshot.items,
            isAwaitingResponse: fixture.isAwaitingResponse,
            revision: fixture.snapshot.revision,
            changeHint: fixture.snapshot.changeHint
        )
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(ofType type: View.Type) -> View? {
        if let match = self as? View { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
