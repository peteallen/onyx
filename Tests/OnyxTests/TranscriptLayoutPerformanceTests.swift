import AppKit
import SwiftUI
import XCTest
@testable import Onyx

final class TranscriptLayoutPerformanceTests: XCTestCase {
    func testPrependHintKeepsLargeHistoryPlanningBounded() {
        let tail = (0..<20_000).map { index in
            makeItem(id: "tail-\(index)", body: "Stable tail \(index)")
        }
        let older = (0..<80).map { index in
            makeItem(id: "older-\(index)", body: "Earlier page \(index)")
        }
        var snapshot = TranscriptPresentationSnapshot(items: tail, revision: 41)
        snapshot.prepend(contentsOf: older)
        var instrumentation = TranscriptCollectionUpdate.PlanningInstrumentation()

        let update = TranscriptCollectionUpdate.plan(
            from: tail,
            to: snapshot.items,
            oldRevision: 41,
            newRevision: snapshot.revision,
            hint: snapshot.changeHint,
            instrumentation: &instrumentation
        )

        XCTAssertEqual(update, .prepend(0..<older.count))
        XCTAssertEqual(instrumentation.inspectedItemCount, 0)
        XCTAssertEqual(instrumentation.hintedUpdateCount, 1)
    }

    @MainActor
    func testHostedPrependKeepsMountedReaderRowAtSameViewportPosition() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: (0..<20_000).map { index in
                TimelineItem(
                    id: "visible-tail-\(index)",
                    kind: .assistantMessage,
                    title: nil,
                    body: "Visible tail row \(index)",
                    status: .completed,
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    detail: nil
                )
            },
            revision: 10
        )
        let hostingView = NSHostingView(
            rootView: TranscriptLayoutMutationHarness(fixture: fixture)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        // Drain the initial tail-follow before choosing the reader's position.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        let scrollView = try XCTUnwrap(collectionView.enclosingScrollView)
        let oldPath = IndexPath(item: 10_000, section: 0)
        collectionView.scrollToItems(at: [oldPath], scrollPosition: .top)
        layout()
        let controller = try XCTUnwrap(collectionView.dataSource as? TranscriptViewController)
        _ = try XCTUnwrap(collectionView.item(at: oldPath))
        let oldFrame = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: oldPath)?.frame
        )
        let oldOffset = oldFrame.minY - scrollView.contentView.bounds.minY
        let indexRebuildsBeforePrepend = controller.prependInstrumentation.displayIndexRebuildCount

        let updateStart = ContinuousClock.now
        fixture.prependEarlierMessages(count: 80)
        layout()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        hostingView.layoutSubtreeIfNeeded()
        let updateElapsed = updateStart.duration(to: .now)

        let newPath = IndexPath(item: oldPath.item + 80, section: 0)
        _ = try XCTUnwrap(collectionView.item(at: newPath))
        let newFrame = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: newPath)?.frame
        )
        let newOffset = newFrame.minY - scrollView.contentView.bounds.minY
        XCTAssertEqual(controller.prependInstrumentation.insertedDisplayRowCount, 80)
        XCTAssertEqual(controller.prependInstrumentation.projectedPrefixItemCount, 80)
        XCTAssertLessThanOrEqual(
            controller.prependInstrumentation.projectedPrefixGroupCount,
            40,
            "Prepend projection work must remain bounded by the incoming page"
        )
        XCTAssertEqual(
            controller.prependInstrumentation.fullReloadCount,
            0,
            "Prepending a valid page should insert native rows instead of reloading the transcript"
        )
        XCTAssertEqual(
            controller.prependInstrumentation.displayIndexRebuildCount,
            indexRebuildsBeforePrepend,
            "A prepend should defer rebuilding historical row lookup maps until a later mutation needs them"
        )
        XCTAssertEqual(
            controller.prependInstrumentation.anchorFallbackScanCount,
            0,
            "A valid prepend should restore its known shifted display index without scanning history"
        )
        XCTAssertEqual(
            controller.projectionStorageMaterializationCount,
            0,
            "A valid prepend should not materialize the already-loaded transcript projection"
        )
        XCTAssertEqual(
            newOffset,
            oldOffset,
            accuracy: 1,
            "The content under the reader's eyes moved while earlier history was inserted"
        )
        XCTAssertLessThan(
            updateElapsed,
            .milliseconds(250),
            "A bounded older-history page blocked the hosted transcript for \(updateElapsed)"
        )
    }

    @MainActor
    func testHostedMixedLargeHistoryKeepsPostPrependTailStreamingBounded() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: (0..<20_000).map { index in
                mixedHistoryItem(
                    id: "large-history-\(index)",
                    index: index,
                    timestamp: Double(index)
                )
            },
            revision: 100
        )
        let hostingView = NSHostingView(
            rootView: TranscriptLayoutMutationHarness(fixture: fixture)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        let controller = try XCTUnwrap(
            collectionView.dataSource as? TranscriptViewController
        )
        let initialDisplayIndexRebuilds =
            controller.prependInstrumentation.displayIndexRebuildCount

        for page in 0..<3 {
            fixture.prependMixedEarlierMessages(page: page, count: 48)
            layout()
        }

        XCTAssertGreaterThan(
            controller.prependInstrumentation.projectedPrefixGroupCount,
            0,
            "The regression must exercise offset-backed prepended activity groups"
        )
        XCTAssertEqual(
            controller.prependInstrumentation.displayIndexRebuildCount,
            initialDisplayIndexRebuilds,
            "Repeated prepends must not rebuild the historical row maps"
        )

        fixture.appendAssistant(body: "", status: .running)
        layout()
        for step in 0..<50 {
            fixture.mutateTail(
                body: "assistant streamed delta \(step)",
                status: .running
            )
            layout()
        }

        fixture.appendActivity(
            id: "bounded-tail-command",
            kind: .command,
            status: .completed
        )
        layout()
        fixture.appendActivity(
            id: "bounded-tail-tool",
            kind: .tool,
            status: .running
        )
        layout()
        for step in 0..<50 {
            fixture.mutateTail(
                body: "tool streamed delta \(step)",
                status: step.isMultiple(of: 2) ? .completed : .running
            )
            layout()
        }

        let instrumentation = controller.prependInstrumentation
        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            15_111,
            "The final running tool should remain beside the completed command without losing history rows"
        )
        XCTAssertEqual(
            instrumentation.displayIndexRebuildCount,
            initialDisplayIndexRebuilds,
            "One hundred tail mutations after prepends must not rebuild all display indexes"
        )
        XCTAssertEqual(
            controller.projectionStorageMaterializationCount,
            0,
            "Neither grouped history nor display history may be materialized by tail streaming"
        )
        XCTAssertEqual(
            instrumentation.projectionFullReloadCount,
            0,
            "Common tail topology changes must use suffix batch updates instead of reloadData"
        )
        XCTAssertGreaterThanOrEqual(
            instrumentation.deferredReloadLookupCount,
            50,
            "Assistant streaming should resolve dirty post-prepend indexes through deferred lookups"
        )
        XCTAssertGreaterThan(instrumentation.nearTailLookupCount, 0)
        XCTAssertEqual(instrumentation.nearTailLookupBudgetExceededCount, 0)
        XCTAssertLessThanOrEqual(
            instrumentation.nearTailInspectedRowCount,
            instrumentation.nearTailLookupCount
                * TranscriptViewController.maximumNearTailLookupRows,
            "Every fallback lookup must obey the hard near-tail row budget"
        )
        XCTAssertLessThanOrEqual(
            instrumentation.tailGroupingInspectedItemCount,
            600,
            "Tool completion toggles may inspect only the bounded mutable grouping tail"
        )
        XCTAssertGreaterThanOrEqual(
            instrumentation.suffixBatchUpdateCount,
            52,
            "Lone-to-group and live-tool rollup transitions should stay on atomic suffix batches"
        )

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testAssistantOnlyPrependShiftsExistingActivityGroupWithoutReloading() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: [
                makeItem(id: "group-command", kind: .command),
                makeItem(id: "group-tool", kind: .tool),
            ],
            revision: 20
        )
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let controller = try host.controller()
        let initialRebuilds = controller.prependInstrumentation.displayIndexRebuildCount

        fixture.prependEarlierMessages(count: 40)
        host.layout()
        fixture.appendActivity(id: "group-tail", kind: .command, status: .completed)
        host.layout()

        let collectionView = try host.collectionView()
        let groupView = try XCTUnwrap(
            try host.mountedView(at: collectionView.numberOfItems(inSection: 0) - 1)
                as? TranscriptActivityGroupView
        )

        XCTAssertEqual(controller.projectionStorageMaterializationCount, 0)
        XCTAssertEqual(controller.prependInstrumentation.projectionFullReloadCount, 0)
        XCTAssertEqual(
            controller.prependInstrumentation.displayIndexRebuildCount,
            initialRebuilds
        )
        XCTAssertEqual(
            groupView.representedItemIDs,
            ["group-command", "group-tool", "group-tail"],
            "An assistant-only prepend must shift the existing activity group before a tail append"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testPostPrependAppendedPlanRemainsIndexedBeyondNearTailBudget() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: (0..<20_000).map { index in
                makeItem(id: "indexed-history-\(index)", body: "History \(index)")
            },
            revision: 30
        )
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let controller = try host.controller()
        fixture.prependEarlierMessages(count: 40)
        host.layout()
        let initialRebuilds = controller.prependInstrumentation.displayIndexRebuildCount

        fixture.appendPlan(id: "indexed-plan")
        host.layout()
        for index in 0..<(TranscriptViewController.maximumNearTailLookupRows + 4) {
            fixture.appendAssistant(body: "separator \(index)", status: .completed)
            host.layout()
        }
        fixture.mutateItem(id: "indexed-plan", body: "Updated after a long visible suffix")
        host.layout()

        let collectionView = try host.collectionView()
        let planDisplayIndex = collectionView.numberOfItems(inSection: 0)
            - TranscriptViewController.maximumNearTailLookupRows
            - 5
        let planView = try XCTUnwrap(
            try host.mountedView(at: planDisplayIndex) as? TranscriptCellView
        )

        XCTAssertEqual(
            controller.prependInstrumentation.displayIndexRebuildCount,
            initialRebuilds,
            "Updating a post-prepend row must use its normalized suffix map"
        )
        XCTAssertEqual(controller.prependInstrumentation.nearTailLookupBudgetExceededCount, 0)
        XCTAssertEqual(controller.projectionStorageMaterializationCount, 0)
        XCTAssertEqual(planView.itemID, "indexed-plan")
        XCTAssertTrue(
            planView.subviews
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("Updated after a long visible suffix"),
            "The normalized suffix map must reload the appended plan itself"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testFirstVisibleTokenAtomicallyReplacesPendingRow() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.isAwaitingResponse = true
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let collectionView = try host.collectionView()
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 2)

        fixture.appendAssistant(body: "First visible token", status: .running)
        host.layout()

        let assistantView = try XCTUnwrap(
            try host.mountedView(at: 1) as? TranscriptCellView
        )

        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            2,
            "The assistant row must replace the waiting row in one hosted update"
        )
        XCTAssertEqual(assistantView.itemID, "hosting-layout-assistant-1")
        XCTAssertTrue(
            assistantView.subviews
                .compactMap { ($0 as? NSTextField)?.stringValue }
                .contains("First visible token")
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testPendingRemovalSharesLoneToGroupSuffixBatch() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.isAwaitingResponse = true
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let collectionView = try host.collectionView()

        fixture.appendActivity(id: "pending-lone", kind: .command, status: .completed)
        host.layout()
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 3)

        fixture.appendActivity(id: "pending-grouped", kind: .tool, status: .completed)
        fixture.isAwaitingResponse = false
        host.layout()

        let groupView = try XCTUnwrap(
            try host.mountedView(at: 1) as? TranscriptActivityGroupView
        )

        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            2,
            "Lone-to-rollup replacement and waiting-row removal must share one update"
        )
        XCTAssertEqual(
            groupView.representedItemIDs,
            ["pending-lone", "pending-grouped"]
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testPendingRemovalSharesEightToNineSuffixBatch() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.isAwaitingResponse = true
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let collectionView = try host.collectionView()

        for index in 0..<8 {
            fixture.appendActivity(
                id: "atomic-rollup-\(index)",
                kind: index.isMultiple(of: 2) ? .command : .tool,
                status: .completed
            )
            host.layout()
        }
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 3)

        fixture.appendActivity(
            id: "atomic-rollup-8",
            kind: .command,
            status: .completed
        )
        fixture.isAwaitingResponse = false
        host.layout()

        let ninthActivityView = try XCTUnwrap(
            try host.mountedView(at: 2) as? TranscriptCellView
        )

        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            3,
            "The ninth sibling insertion must be atomic with waiting-row removal"
        )
        XCTAssertEqual(ninthActivityView.itemID, "atomic-rollup-8")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testPendingInsertionSharesHistoryPrependBatch() throws {
        let fixture = TranscriptLayoutMutationFixture()
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }
        host.layout()
        let collectionView = try host.collectionView()
        let controller = try host.controller()
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 1)

        fixture.prependEarlierMessages(count: 40)
        fixture.isAwaitingResponse = true
        host.layout()

        let pendingView = try host.mountedView(at: 41)

        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 42)
        XCTAssertEqual(controller.prependInstrumentation.insertedDisplayRowCount, 40)
        XCTAssertEqual(controller.prependInstrumentation.fullReloadCount, 0)
        XCTAssertEqual(
            pendingView.accessibilityLabel(),
            "Assistant response status"
        )
        XCTAssertEqual(pendingView.accessibilityValue() as? String, "Working")
        pendingView.layoutSubtreeIfNeeded()
        let waitingLabel = try XCTUnwrap(
            pendingView.subviews
                .compactMap { $0 as? NSTextField }
                .first(where: { $0.stringValue == "Working" })
        )
        XCTAssertEqual(
            try XCTUnwrap(waitingLabel.font).pointSize,
            OnyxTypography.reading,
            accuracy: 0.1
        )
        XCTAssertEqual(
            waitingLabel.frame.minX,
            OnyxWorkspaceMetrics.conversationTextInset,
            accuracy: 0.1
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    private func makeItem(
        id: String,
        kind: TimelineItemKind = .assistantMessage,
        body: String = "Finished"
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: kind,
            title: kind == .command ? "Run command" : (kind == .tool ? "Use tool" : nil),
            body: body,
            status: .completed,
            timestamp: Date(timeIntervalSince1970: 100),
            detail: nil
        )
    }

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

        // Regression coverage for the AppKit invalid-update crash at the
        // activity-rollup boundary. Eight completed routine activities are
        // represented by one collapsed collection row; appending the ninth
        // changes that same tail group and inserts a new sibling row in one
        // projection update. The data source must apply both mutations as one
        // batch while the hosted SwiftUI view is laying out.
        fixture.appendAssistant(body: "Rollup boundary", status: .completed)
        layout()
        for index in 0..<8 {
            fixture.appendActivity(
                id: "rollup-\(index)",
                kind: index.isMultiple(of: 2) ? .command : .tool,
                status: .completed
            )
            layout(width: index.isMultiple(of: 2) ? 520 : 900)
        }
        let eightActivityRowCount = collectionView.numberOfItems(inSection: 0)
        fixture.appendActivity(id: "rollup-8", kind: .command, status: .completed)
        layout(width: 720)
        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            eightActivityRowCount + 1,
            "The ninth activity should add one sibling row after the bounded rollup"
        )

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

    @MainActor
    func testHostingViewSurvivesAppendPastExpandedActivityGroupBoundary() throws {
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
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        for index in 0..<8 {
            fixture.appendActivity(
                id: "expanded-rollup-\(index)",
                kind: index.isMultiple(of: 2) ? .command : .tool,
                status: .completed
            )
            layout()
        }
        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            2,
            "The user message and collapsed eight-activity rollup should each occupy one row"
        )

        let collapsedGroup = try XCTUnwrap(
            hostingView.firstDescendant(ofType: TranscriptActivityGroupView.self)
        )
        XCTAssertFalse(collapsedGroup.isExpanded)
        XCTAssertTrue(collapsedGroup.accessibilityPerformPress())
        layout()

        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            10,
            "Opening the rollup should restore its eight child rows below the summary"
        )

        fixture.appendActivity(id: "expanded-rollup-8", kind: .command, status: .completed)
        layout()

        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            11,
            "The ninth activity should append beside the still-expanded bounded rollup"
        )

        // Drain deferred follow-scroll work before releasing the AppKit host.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testHostingViewSurvivesCollapsedBoundaryWithInlinePendingResponse() throws {
        let fixture = TranscriptLayoutMutationFixture()
        fixture.isAwaitingResponse = true
        let hostingView = NSHostingView(
            rootView: TranscriptLayoutMutationHarness(fixture: fixture)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        func layout() {
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            hostingView.layoutSubtreeIfNeeded()
        }

        layout()
        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            2,
            "The inline waiting row should be mounted before activity output arrives"
        )

        for index in 0..<8 {
            fixture.appendActivity(
                id: "pending-rollup-\(index)",
                kind: index.isMultiple(of: 2) ? .command : .tool,
                status: .completed
            )
            layout()
        }
        let eightActivityRowCount = collectionView.numberOfItems(inSection: 0)
        XCTAssertEqual(
            eightActivityRowCount,
            3,
            "Eight completed activities should be one rollup plus the user and waiting rows"
        )

        // The ninth activity must be inserted before the existing pending row.
        // This is the production ordering that previously left AppKit with a
        // stale item count and raised NSInternalInconsistencyException.
        fixture.appendActivity(
            id: "pending-rollup-8",
            kind: .command,
            status: .completed
        )
        layout()
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), eightActivityRowCount + 1)

        fixture.isAwaitingResponse = false
        layout()
        XCTAssertEqual(
            collectionView.numberOfItems(inSection: 0),
            eightActivityRowCount,
            "Removing the waiting row after the boundary append must not disturb activity rows"
        )

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    func testHostedRetryabilityChangeReloadsRowHeightWithoutTranscriptRevisionChange() throws {
        let responseBody = String(
            repeating: "The provider response remains readable while the recovery action is available. ",
            count: 14
        )
        let failedResponse = TimelineItem(
            id: "retry-layout-response",
            kind: .assistantMessage,
            title: nil,
            body: responseBody,
            status: .failed,
            timestamp: .now,
            detail: "The provider did not finish this response."
        )
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: [
                TimelineItem(
                    id: "retry-layout-user",
                    kind: .userMessage,
                    title: nil,
                    body: "Build the page.",
                    status: .completed,
                    timestamp: .now,
                    detail: nil
                ),
                failedResponse,
            ],
            revision: 17
        )
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }

        host.layout()
        let collectionView = try host.collectionView()
        _ = try host.mountedView(at: 1)
        let responsePath = IndexPath(item: 1, section: 0)
        let initialAttributes = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: responsePath)
        )
        let normalHeight = TranscriptCellView.height(
            for: failedResponse,
            width: initialAttributes.frame.width,
            isExpanded: true,
            isRetryable: false
        )
        XCTAssertEqual(initialAttributes.frame.height, normalHeight, accuracy: 1)

        // This is intentionally a presentation-only transition: the items and
        // transcript revision stay byte-for-byte identical. A cell update or
        // needsLayout flag alone is not enough because the flow layout retains
        // its previous delegate-provided row height.
        fixture.retryableFailedResponseItemID = failedResponse.id
        host.layout()

        let retryAttributes = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: responsePath)
        )
        let retryHeight = TranscriptCellView.height(
            for: failedResponse,
            width: retryAttributes.frame.width,
            isExpanded: true,
            isRetryable: true
        )
        XCTAssertGreaterThan(
            retryHeight,
            normalHeight,
            "Reserving the Retry action should increase this wrapped failure row"
        )
        XCTAssertEqual(retryAttributes.frame.height, retryHeight, accuracy: 1)

        let cell = try XCTUnwrap(
            collectionView.item(at: responsePath)?.view as? TranscriptCellView
        )
        XCTAssertEqual(cell.frame.height, retryHeight, accuracy: 1)
        XCTAssertFalse(cell.retryControl.isHidden)
        XCTAssertFalse(cell.retryControl.frame.intersects(cell.bodyFrame))
    }

    @MainActor
    func testHostedAppendCanClearRetryWithoutRetainingFailedRowHeight() throws {
        let responseBody = String(
            repeating: "The failed response should widen again when a follow-up starts. ",
            count: 15
        )
        let failedResponse = TimelineItem(
            id: "retry-clear-response",
            kind: .assistantMessage,
            title: nil,
            body: responseBody,
            status: .failed,
            timestamp: .now,
            detail: "The provider did not finish this response."
        )
        let fixture = TranscriptLayoutMutationFixture()
        fixture.snapshot = TranscriptPresentationSnapshot(
            items: [
                TimelineItem(
                    id: "retry-clear-user",
                    kind: .userMessage,
                    title: nil,
                    body: "Build the page.",
                    status: .completed,
                    timestamp: .now,
                    detail: nil
                ),
                failedResponse,
            ],
            revision: 23
        )
        fixture.retryableFailedResponseItemID = failedResponse.id
        let host = TranscriptHostedFixture(fixture: fixture)
        defer { host.close() }

        host.layout()
        let collectionView = try host.collectionView()
        _ = try host.mountedView(at: 1)
        let responsePath = IndexPath(item: 1, section: 0)
        let retryAttributes = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: responsePath)
        )
        let retryHeight = TranscriptCellView.height(
            for: failedResponse,
            width: retryAttributes.frame.width,
            isExpanded: true,
            isRetryable: true
        )
        XCTAssertEqual(retryAttributes.frame.height, retryHeight, accuracy: 1)

        // A normal send publishes both changes together: Retry eligibility
        // clears while an optimistic user row is appended. The old failure is
        // outside that append suffix, but its presentation width still changed.
        fixture.retryableFailedResponseItemID = nil
        var appended = fixture.snapshot
        appended.append(
            TimelineItem(
                id: "retry-clear-follow-up",
                kind: .userMessage,
                title: nil,
                body: "Try a smaller version.",
                status: .completed,
                timestamp: .now,
                detail: nil
            )
        )
        fixture.snapshot = appended
        host.layout()

        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 3)
        let normalAttributes = try XCTUnwrap(
            collectionView.layoutAttributesForItem(at: responsePath)
        )
        let normalHeight = TranscriptCellView.height(
            for: failedResponse,
            width: normalAttributes.frame.width,
            isExpanded: true,
            isRetryable: false
        )
        XCTAssertLessThan(normalHeight, retryHeight)
        XCTAssertEqual(normalAttributes.frame.height, normalHeight, accuracy: 1)
        let cell = try XCTUnwrap(
            collectionView.item(at: responsePath)?.view as? TranscriptCellView
        )
        XCTAssertEqual(cell.frame.height, normalHeight, accuracy: 1)
        XCTAssertTrue(cell.retryControl.isHidden)
    }

    func testFlowMetricsAlwaysLeaveStrictLayoutWidth() {
        for collectionWidth: CGFloat in [0, 0.5, 1, 2, 48, 320, 520, 720, 900, 1_200] {
            let metrics = TranscriptFlowMetrics(collectionWidth: collectionWidth)

            XCTAssertTrue(metrics.itemWidth.isFinite)
            XCTAssertTrue(metrics.leadingInset.isFinite)
            XCTAssertTrue(metrics.trailingInset.isFinite)
            XCTAssertGreaterThanOrEqual(metrics.itemWidth, 0)
            XCTAssertGreaterThanOrEqual(metrics.leadingInset, 0)
            XCTAssertGreaterThanOrEqual(metrics.trailingInset, 0)
            if collectionWidth > TranscriptFlowMetrics.layoutSafetyWidth {
                XCTAssertLessThan(
                    metrics.itemWidth + metrics.leadingInset + metrics.trailingInset,
                    collectionWidth
                )
            } else {
                XCTAssertEqual(metrics.itemWidth, 0)
                XCTAssertEqual(metrics.leadingInset, 0)
                XCTAssertEqual(metrics.trailingInset, 0)
            }
        }
    }

    func testWideTranscriptFillsThePaneBetweenBalancedSideGutters() {
        let metrics = TranscriptFlowMetrics(collectionWidth: 1_200)

        XCTAssertEqual(
            TranscriptFlowMetrics.preferredLeadingInset,
            OnyxWorkspaceMetrics.preferredConversationSideInset
        )
        XCTAssertEqual(
            metrics.leadingInset,
            TranscriptFlowMetrics.preferredLeadingInset,
            accuracy: 0.001
        )
        XCTAssertEqual(metrics.trailingInset, metrics.leadingInset, accuracy: 0.001)
        XCTAssertEqual(
            metrics.itemWidth,
            1_200 - metrics.leadingInset - metrics.trailingInset
                - TranscriptFlowMetrics.layoutSafetyWidth,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(metrics.itemWidth, 1_100)
    }

    @MainActor
    func testShortUserMessageFitsOneLineInsideItsBubble() throws {
        let body = "sup fam"
        let item = TimelineItem(
            id: "short-user-message",
            kind: .userMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let width: CGFloat = 1_120
        let hostingView = NSHostingView(
            rootView: NativeTranscriptView(items: [item])
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        hostingView.layoutSubtreeIfNeeded()

        let collectionView = try XCTUnwrap(
            hostingView.firstDescendant(ofType: NSCollectionView.self)
        )
        let indexPath = IndexPath(item: 0, section: 0)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .top)
        hostingView.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(
            collectionView.item(at: indexPath)?.view as? TranscriptCellView
        )

        let bodyLabel = try XCTUnwrap(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.attributedStringValue.string == body && !$0.isHidden }
        )
        let requiredBodySize = try XCTUnwrap(bodyLabel.cell?.cellSize(forBounds: NSRect(
            x: 0,
            y: 0,
            width: bodyLabel.bounds.width,
            height: .greatestFiniteMagnitude
        )))
        XCTAssertGreaterThanOrEqual(
            bodyLabel.bounds.width,
            bodyLabel.intrinsicContentSize.width,
            "A short outgoing message should not wrap because its text field is narrower than its intrinsic single-line width"
        )
        XCTAssertLessThanOrEqual(
            requiredBodySize.height,
            bodyLabel.bounds.height + 0.5,
            "The native text cell should lay the outgoing message out on the same single line reserved by the row"
        )
        XCTAssertLessThanOrEqual(bodyLabel.frame.maxY, cell.messageBubbleFrame.maxY)
        XCTAssertGreaterThanOrEqual(bodyLabel.frame.minY, cell.messageBubbleFrame.minY)
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
        var failed = running
        failed.status = .failed
        let newItems = [failed, makeItem(id: "assistant", body: "Finished")]
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

        let expectedFailedHeight = TranscriptCellView.height(
            for: failed,
            width: 640,
            isExpanded: false
        )
        let renderedFailedHeight = state.height(
            for: failed,
            width: 640,
            isExpanded: false
        ) {
            expectedFailedHeight
        }

        XCTAssertEqual(
            runningHeight,
            expectedFailedHeight,
            "A failed routine event intentionally stays the same compact height as live work"
        )
        XCTAssertEqual(renderedFailedHeight, expectedFailedHeight)
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

    private func mixedHistoryItem(
        id: String,
        index: Int,
        timestamp: Double
    ) -> TimelineItem {
        let kind: TimelineItemKind = switch index % 4 {
        case 1: .command
        case 2: .tool
        default: .assistantMessage
        }
        return TimelineItem(
            id: id,
            kind: kind,
            title: kind == .command ? "Run command" : (kind == .tool ? "Use tool" : nil),
            body: "Stable mixed history \(index)",
            status: .completed,
            timestamp: Date(timeIntervalSince1970: timestamp),
            detail: nil
        )
    }
}

@MainActor
private final class TranscriptLayoutMutationFixture: ObservableObject {
    @Published var isAwaitingResponse = false
    @Published var retryableFailedResponseItemID: String?
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

    func appendPlan(id: String) {
        var next = snapshot
        next.append(
            TimelineItem(
                id: id,
                kind: .plan,
                title: "Plan",
                body: "Initial plan",
                status: .running,
                timestamp: Date(timeIntervalSince1970: 1_000 + Double(next.items.count)),
                detail: nil
            )
        )
        snapshot = next
    }

    func prependEarlierMessages(count: Int) {
        var next = snapshot
        next.prepend(
            contentsOf: (0..<count).map { index in
                TimelineItem(
                    id: "earlier-hosted-\(index)",
                    kind: .assistantMessage,
                    title: nil,
                    body: "Earlier hosted row \(index)",
                    status: .completed,
                    timestamp: Date(timeIntervalSince1970: Double(index - count)),
                    detail: nil
                )
            }
        )
        snapshot = next
    }

    func prependMixedEarlierMessages(page: Int, count: Int) {
        var next = snapshot
        next.prepend(
            contentsOf: (0..<count).map { index in
                let kind: TimelineItemKind = switch index % 4 {
                case 1: .command
                case 2: .tool
                default: .assistantMessage
                }
                return TimelineItem(
                    id: "earlier-mixed-\(page)-\(index)",
                    kind: kind,
                    title: kind == .command
                        ? "Run command"
                        : (kind == .tool ? "Use tool" : nil),
                    body: "Earlier mixed page \(page), row \(index)",
                    status: .completed,
                    timestamp: Date(
                        timeIntervalSince1970: -Double((page + 1) * count - index)
                    ),
                    detail: nil
                )
            }
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

    func mutateItem(id: String, body: String) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        next.mutateRows(IndexSet(integer: index)) { items in
            items[index].body = body
        }
        snapshot = next
    }
}

@MainActor
private final class TranscriptHostedFixture {
    let hostingView: NSHostingView<TranscriptLayoutMutationHarness>
    let window: NSWindow

    init(fixture: TranscriptLayoutMutationFixture) {
        hostingView = NSHostingView(
            rootView: TranscriptLayoutMutationHarness(fixture: fixture)
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
    }

    func layout() {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
        hostingView.layoutSubtreeIfNeeded()
    }

    func collectionView() throws -> NSCollectionView {
        try XCTUnwrap(hostingView.firstDescendant(ofType: NSCollectionView.self))
    }

    func controller() throws -> TranscriptViewController {
        try XCTUnwrap(try collectionView().dataSource as? TranscriptViewController)
    }

    func mountedView(at itemIndex: Int) throws -> NSView {
        let collectionView = try collectionView()
        let path = IndexPath(item: itemIndex, section: 0)
        collectionView.scrollToItems(at: [path], scrollPosition: .top)
        layout()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        hostingView.layoutSubtreeIfNeeded()
        return try XCTUnwrap(collectionView.item(at: path)?.view)
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

private struct TranscriptLayoutMutationHarness: View {
    @ObservedObject var fixture: TranscriptLayoutMutationFixture

    var body: some View {
        NativeTranscriptView(
            items: fixture.snapshot.items,
            isAwaitingResponse: fixture.isAwaitingResponse,
            revision: fixture.snapshot.revision,
            changeHint: fixture.snapshot.changeHint,
            retryableFailedResponseItemID: fixture.retryableFailedResponseItemID
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
