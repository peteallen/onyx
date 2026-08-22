import CoreGraphics
import XCTest
@testable import Onyx

final class WorkspacePaneLayoutTests: XCTestCase {
    func testCompactSidebarToggleUsesDisplayedVisibilityAndDismissesInspector() {
        let sidebarDisplayed = WorkspacePaneLayout.isSidebarDisplayed(
            sidebarRequested: true,
            inspectorVisible: true,
            isCompact: true
        )
        XCTAssertFalse(sidebarDisplayed)

        let revealTarget = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: sidebarDisplayed,
            inspectorVisible: true,
            isCompact: true
        )
        XCTAssertTrue(revealTarget.sidebarRequested)
        XCTAssertFalse(revealTarget.inspectorVisible)
        XCTAssertTrue(WorkspacePaneLayout.isSidebarDisplayed(
            sidebarRequested: revealTarget.sidebarRequested,
            inspectorVisible: revealTarget.inspectorVisible,
            isCompact: true
        ))

        let hideTarget = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: true,
            inspectorVisible: false,
            isCompact: true
        )
        XCTAssertFalse(hideTarget.sidebarRequested)
        XCTAssertFalse(hideTarget.inspectorVisible)
    }

    func testWideSidebarTogglePreservesVisibleInspector() {
        let target = WorkspacePaneLayout.sidebarToggleTarget(
            sidebarDisplayed: false,
            inspectorVisible: true,
            isCompact: false
        )

        XCTAssertTrue(target.sidebarRequested)
        XCTAssertTrue(target.inspectorVisible)
    }

    func testStoredWidthsClampInvalidAndExtremeValues() {
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(.infinity),
            WorkspacePaneLayout.sidebarDefaultWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(-1_000),
            WorkspacePaneLayout.sidebarMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredSidebarWidth(1_000),
            WorkspacePaneLayout.sidebarMaximumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(.nan),
            WorkspacePaneLayout.inspectorDefaultWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(-1_000),
            WorkspacePaneLayout.inspectorMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.clampedStoredInspectorWidth(1_000),
            WorkspacePaneLayout.inspectorMaximumWidth
        )
    }

    func testDisplayedWidthsLeaveConversationRoomAndRespectTheOtherPane() {
        let sidebar = WorkspacePaneLayout.displayedSidebarWidth(
            storedWidth: WorkspacePaneLayout.sidebarMaximumWidth,
            totalWidth: 1_180,
            inspectorVisible: true,
            inspectorWidth: WorkspacePaneLayout.inspectorDefaultWidth
        )
        XCTAssertEqual(sidebar, 368, accuracy: 0.001)

        let inspector = WorkspacePaneLayout.displayedInspectorWidth(
            storedWidth: WorkspacePaneLayout.inspectorMaximumWidth,
            totalWidth: 1_180,
            sidebarVisible: true,
            sidebarWidth: sidebar
        )
        XCTAssertEqual(inspector, WorkspacePaneLayout.inspectorDefaultWidth, accuracy: 0.001)

        let center = 1_180
            - WorkspacePaneLayout.commandRailWidth
            - WorkspacePaneLayout.dividerWidth * 2
            - sidebar
            - inspector
        XCTAssertGreaterThanOrEqual(center, WorkspacePaneLayout.minimumConversationWidth)
    }

    func testInspectorCanUseTheWidthWhenSidebarIsCollapsed() {
        let inspector = WorkspacePaneLayout.displayedInspectorWidth(
            storedWidth: WorkspacePaneLayout.inspectorMaximumWidth,
            totalWidth: 900,
            sidebarVisible: false
        )

        XCTAssertEqual(inspector, 421, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            900
                - WorkspacePaneLayout.commandRailWidth
                - WorkspacePaneLayout.dividerWidth
                - inspector,
            WorkspacePaneLayout.minimumConversationWidth
        )
    }

    func testAccessibilityAdjustmentsStayWithinIntrinsicBounds() {
        XCTAssertEqual(
            WorkspacePaneLayout.adjustedSidebarWidth(
                WorkspacePaneLayout.sidebarMinimumWidth,
                increasing: false
            ),
            WorkspacePaneLayout.sidebarMinimumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.adjustedInspectorWidth(
                WorkspacePaneLayout.inspectorMaximumWidth,
                increasing: true
            ),
            WorkspacePaneLayout.inspectorMaximumWidth
        )
        XCTAssertEqual(
            WorkspacePaneLayout.accessibilityValue(for: 264.4),
            "264 points wide"
        )
    }

    func testPaneWidthPreferenceKeysRemainWindowScoped() {
        let namespace = OnyxPreferenceNamespace(prefix: "Onyx.window.test")
        XCTAssertEqual(
            namespace.key(WorkspacePaneLayout.sidebarWidthPreferenceSuffix),
            "Onyx.window.test.sidebarWidth"
        )
        XCTAssertEqual(
            namespace.key(WorkspacePaneLayout.inspectorWidthPreferenceSuffix),
            "Onyx.window.test.inspectorWidth"
        )
    }
}
