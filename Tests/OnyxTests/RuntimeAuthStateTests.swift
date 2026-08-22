import XCTest
@testable import Onyx

final class RuntimeAuthStateTests: XCTestCase {
    func testPlanDisplayLabelHumanizesProviderIdentifiers() {
        let state = RuntimeAuthState(
            mode: .chatgpt,
            email: nil,
            planLabel: "self_serve_business_usage_based",
            requiresAuthentication: true
        )

        XCTAssertEqual(state.planDisplayLabel, "Self Serve Business Usage Based")
    }

    func testPlanDisplayLabelPreservesFriendlyLabelsAndHandlesMissingValues() {
        let pro = RuntimeAuthState(
            mode: .chatgpt,
            email: nil,
            planLabel: "Pro",
            requiresAuthentication: true
        )
        let missing = RuntimeAuthState(
            mode: .chatgpt,
            email: nil,
            planLabel: "  ",
            requiresAuthentication: true
        )

        XCTAssertEqual(pro.planDisplayLabel, "Pro")
        XCTAssertNil(missing.planDisplayLabel)
    }
}
