import XCTest
@testable import Onyx

final class TaskSidebarPresentationTests: XCTestCase {
    func testOnlyRoutineReadyStateOmitsItsSidebarLabel() {
        XCTAssertFalse(RuntimeTaskAttention.ready.showsSidebarAttentionLabel)

        let visibleStates: [RuntimeTaskAttention] = [
            .working,
            .needsInput,
            .needsApproval,
            .failed,
            .unknown,
        ]
        for state in visibleStates {
            XCTAssertTrue(
                state.showsSidebarAttentionLabel,
                "\(state.label) should remain visually distinguishable in the sidebar"
            )
        }
    }
}
