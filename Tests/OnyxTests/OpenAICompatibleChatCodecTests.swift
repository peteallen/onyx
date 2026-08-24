import XCTest
@testable import Onyx

final class OpenAICompatibleChatCodecTests: XCTestCase {
    func testEncodesFunctionToolSchemaExactly() {
        let request = OpenAICompatibleChatRequest(
            model: "fixture-model",
            messages: [.init(role: .user, text: "What is the weather?")],
            stream: false,
            reasoningEffort: nil,
            includeStreamingUsage: false,
            requestBehavior: .init(),
            tools: [
                .init(
                    name: "get_weather",
                    description: "Get the current weather for a city.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "city": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([.string("city")]),
                        "additionalProperties": .bool(false),
                    ]),
                    strict: true
                ),
            ]
        )

        XCTAssertEqual(
            request.payload["tools"],
            .array([
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string("get_weather"),
                        "description": .string("Get the current weather for a city."),
                        "parameters": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "city": .object([
                                    "type": .string("string"),
                                ]),
                            ]),
                            "required": .array([.string("city")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "strict": .bool(true),
                    ]),
                ]),
            ])
        )
    }

    func testEncodesAssistantToolCallsAndCorrelatedToolResults() {
        let request = OpenAICompatibleChatRequest(
            model: "fixture-model",
            messages: [
                .init(role: .user, text: "What is the weather in Denver?"),
                .init(
                    assistantToolCalls: [
                        .init(
                            id: "call_weather_1",
                            name: "get_weather",
                            arguments: #"{"city":"Denver"}"#
                        ),
                    ]
                ),
                .init(
                    toolCallID: "call_weather_1",
                    result: #"{"temperature":72}"#
                ),
            ],
            stream: true,
            reasoningEffort: nil,
            includeStreamingUsage: false,
            requestBehavior: .init()
        )

        XCTAssertEqual(
            request.payload["messages"],
            .array([
                .object([
                    "role": .string("user"),
                    "content": .string("What is the weather in Denver?"),
                ]),
                .object([
                    "role": .string("assistant"),
                    "content": .null,
                    "tool_calls": .array([
                        .object([
                            "id": .string("call_weather_1"),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string("get_weather"),
                                "arguments": .string(#"{"city":"Denver"}"#),
                            ]),
                        ]),
                    ]),
                ]),
                .object([
                    "role": .string("tool"),
                    "content": .string(#"{"temperature":72}"#),
                    "tool_call_id": .string("call_weather_1"),
                ]),
            ])
        )
    }
}
