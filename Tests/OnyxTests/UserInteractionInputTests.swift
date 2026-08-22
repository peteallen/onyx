import XCTest
@testable import Onyx

final class UserInteractionInputTests: XCTestCase {
    func testSecretQuestionAnswersPreserveExactWhitespace() {
        XCTAssertEqual(
            UserInteractionInput.questionAnswer("  temporary token\n", isSecret: true),
            "  temporary token\n"
        )
        XCTAssertEqual(UserInteractionInput.questionAnswer("   ", isSecret: true), "   ")
        XCTAssertNil(UserInteractionInput.questionAnswer("", isSecret: true))
    }

    func testOrdinaryQuestionAnswersAreTrimmed() {
        XCTAssertEqual(
            UserInteractionInput.questionAnswer("  Current workspace\n", isSecret: false),
            "Current workspace"
        )
        XCTAssertNil(UserInteractionInput.questionAnswer(" \n\t ", isSecret: false))
    }

    func testSecretFormFormatsPreserveExactWhitespace() {
        XCTAssertEqual(
            UserInteractionInput.formText(" pass phrase \n", format: "password"),
            " pass phrase \n"
        )
        XCTAssertEqual(
            UserInteractionInput.formText(" api key ", format: "SECRET"),
            " api key "
        )
        XCTAssertEqual(
            UserInteractionInput.formText(" https://example.com \n", format: "uri"),
            "https://example.com"
        )
    }

    func testFloatingPointFormNumbersMustBeFinite() {
        XCTAssertEqual(
            UserInteractionInput.formNumber(" 1.25 ", integerOnly: false),
            .number(1.25)
        )
        XCTAssertNil(UserInteractionInput.formNumber("nan", integerOnly: false))
        XCTAssertNil(UserInteractionInput.formNumber("inf", integerOnly: false))
        XCTAssertNil(UserInteractionInput.formNumber("-inf", integerOnly: false))
        XCTAssertNil(UserInteractionInput.formNumber("1e309", integerOnly: false))
    }

    func testIntegerFormNumbersRemainStrictIntegers() {
        XCTAssertEqual(UserInteractionInput.formNumber(" 42 ", integerOnly: true), .integer(42))
        XCTAssertNil(UserInteractionInput.formNumber("42.0", integerOnly: true))
        XCTAssertNil(UserInteractionInput.formNumber("999999999999999999999999", integerOnly: true))
    }

    func testUntouchedOptionalTogglesAreOmittedInsteadOfSilentlyBecomingFalse() {
        XCTAssertFalse(UserInteractionInput.shouldIncludeToggle(isRequired: false, wasTouched: false))
        XCTAssertTrue(UserInteractionInput.shouldIncludeToggle(isRequired: false, wasTouched: true))
        XCTAssertTrue(UserInteractionInput.shouldIncludeToggle(isRequired: true, wasTouched: false))
    }
}
