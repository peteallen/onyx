import XCTest
@testable import Onyx

final class ShellAccessibilityTests: XCTestCase {
    func testTaskStatusesHavePlainLanguageVoiceOverLabels() {
        XCTAssertEqual(RuntimeThreadStatus.idle.accessibilityLabel, "Ready")
        XCTAssertEqual(RuntimeThreadStatus.running.accessibilityLabel, "Working")
        XCTAssertEqual(RuntimeThreadStatus.waitingForInput.accessibilityLabel, "Needs input")
        XCTAssertEqual(RuntimeThreadStatus.waitingForApproval.accessibilityLabel, "Needs approval")
        XCTAssertEqual(RuntimeThreadStatus.failed.accessibilityLabel, "Failed")
        XCTAssertEqual(RuntimeThreadStatus.unknown.accessibilityLabel, "Status unknown")
    }

    func testConnectionStatesHaveUsefulVoiceOverValues() {
        XCTAssertEqual(RuntimeConnectionState.connected("Codex").onyxAccessibilityValue, "Connected: Codex")
        XCTAssertEqual(RuntimeConnectionState.connecting.onyxAccessibilityValue, "Connecting to Codex")
        XCTAssertEqual(RuntimeConnectionState.failed("Runtime stopped").onyxAccessibilityValue, "Connection failed: Runtime stopped")
        XCTAssertEqual(RuntimeConnectionState.disconnected.onyxAccessibilityValue, "Disconnected")
    }

    func testConnectionStatesDoNotRelyOnColorAlone() {
        XCTAssertEqual(RuntimeConnectionState.connected("Codex").onyxAccessibilitySymbol, "checkmark")
        XCTAssertEqual(RuntimeConnectionState.connecting.onyxAccessibilitySymbol, "ellipsis")
        XCTAssertEqual(RuntimeConnectionState.failed("Runtime stopped").onyxAccessibilitySymbol, "exclamationmark")
        XCTAssertEqual(RuntimeConnectionState.disconnected.onyxAccessibilitySymbol, "minus")
    }

    func testWaitingAndFailedTaskStatesHaveDistinctSymbols() {
        XCTAssertEqual(RuntimeThreadStatus.waitingForApproval.sidebarStatusSymbol, "exclamationmark.circle.fill")
        XCTAssertEqual(RuntimeThreadStatus.waitingForInput.sidebarStatusSymbol, "questionmark.circle.fill")
        XCTAssertEqual(RuntimeThreadStatus.failed.sidebarStatusSymbol, "xmark.circle.fill")
        XCTAssertNotEqual(
            RuntimeThreadStatus.waitingForApproval.sidebarStatusSymbol,
            RuntimeThreadStatus.failed.sidebarStatusSymbol
        )
    }

    func testTerminalHeightKeyboardAndVoiceOverAdjustmentStaysWithinBounds() {
        XCTAssertEqual(
            TerminalDrawerLayout.adjustedHeight(
                TerminalDrawerLayout.minimumHeight,
                increasing: false
            ),
            TerminalDrawerLayout.minimumHeight
        )
        XCTAssertEqual(TerminalDrawerLayout.adjustedHeight(238, increasing: true), 262)
        XCTAssertEqual(TerminalDrawerLayout.adjustedHeight(238, increasing: false), 214)
        XCTAssertEqual(
            TerminalDrawerLayout.adjustedHeight(
                TerminalDrawerLayout.maximumHeight,
                increasing: true
            ),
            TerminalDrawerLayout.maximumHeight
        )
        XCTAssertEqual(TerminalDrawerLayout.accessibilityValue(for: 238.4), "238 points high")
    }
}
