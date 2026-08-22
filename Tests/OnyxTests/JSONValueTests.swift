import XCTest
@testable import Onyx

final class JSONValueTests: XCTestCase {
    func testRoundTripsMixedJSONWithoutLosingIntegerIDs() throws {
        let value = JSONValue.object([
            "id": .integer(42),
            "method": .string("thread/list"),
            "params": .object([
                "archived": .bool(false),
                "sourceKinds": .array([.string("appServer"), .string("cli")]),
                "nullable": .null,
            ]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["id"]?.intValue, 42)
    }

    func testDecodesStringRequestID() throws {
        let data = Data(#"{"id":"approval-7","method":"item/commandExecution/requestApproval","params":{}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(value["id"]?.stringValue, "approval-7")
    }
}
