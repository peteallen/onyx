import AppKit
import XCTest
@testable import Onyx

final class TranscriptLayoutPerformanceTests: XCTestCase {
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
