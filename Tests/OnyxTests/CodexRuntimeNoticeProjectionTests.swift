import XCTest
@testable import Onyx

final class CodexRuntimeNoticeProjectionTests: XCTestCase {
    func testExtractsReadableMessageFromStructuredRuntimeLog() {
        let log = #"{"timestamp":"2026-08-29T21:23:22Z","level":"ERROR","fields":{"message":"workspace watcher failed: permission denied"},"target":"codex_core::watcher"}"#

        XCTAssertEqual(
            CodexRuntimeNoticeProjection.detail(from: log),
            "workspace watcher failed: permission denied"
        )
    }

    func testExtractsProviderMessageFromEmbeddedErrorJSON() {
        let log = #"request failed with status 503: {"error":{"message":"The provider is temporarily unavailable.","code":"unavailable"}}"#

        XCTAssertEqual(
            CodexRuntimeNoticeProjection.detail(from: log),
            "The provider is temporarily unavailable."
        )
    }

    func testExtractsEmbeddedProviderMessageFromStructuredRuntimeLog() {
        let log = #"{"timestamp":"2026-08-29T21:23:22Z","level":"ERROR","fields":{"message":"request failed with status 503: {\"error\":{\"message\":\"The provider is temporarily unavailable.\",\"code\":\"unavailable\"}}"},"target":"codex_analytics::client"}"#

        XCTAssertEqual(
            CodexRuntimeNoticeProjection.detail(from: log),
            "The provider is temporarily unavailable."
        )
    }

    func testBoundsAndRedactsPlainRuntimeDiagnostic() {
        let secret = "Bearer secret-token-value"
        let log = "error Authorization: \(secret) " + String(repeating: "more detail ", count: 100)

        let detail = CodexRuntimeNoticeProjection.detail(from: log)

        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.contains(secret) == true)
        XCTAssertTrue(detail?.hasSuffix("…") == true)
        XCTAssertLessThanOrEqual(detail?.count ?? .max, 481)
    }
}
