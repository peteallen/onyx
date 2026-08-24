import Foundation
import XCTest
@testable import Onyx

final class OpenAICompatibleResponsesSSESanitizerTests: XCTestCase {
    func testSplitChunksCRLFAndMultipleFramesFlushPromptly() throws {
        let stream = Data(
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"hé\"}\r\n\r\n"
                .appending("data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"hé\"}\n\n")
                .utf8
        )

        let whole = try sanitize(stream, chunkSizes: [stream.count])
        let split = try sanitize(stream, chunkSizes: Array(repeating: 1, count: stream.count))

        XCTAssertEqual(whole.frames, split.frames)
        let text = String(decoding: whole.frames, as: UTF8.self)
        XCTAssertTrue(text.contains("response.output_text.delta"))
        XCTAssertTrue(text.contains("response.output_text.done"))
        XCTAssertTrue(text.contains("hé"))
    }

    func testRedactsLiteralMixedUnicodeEscapesNestedJSONStringsAndKeys() throws {
        let secret = "abc/🔐"
        let nested = #"{\"token\":\"\\u0061b\\u0063\\/\\ud83d\\udd10\"}"#
        let frame = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,"
            + "\"a\\u0062c\\/\\ud83d\\udd10\":\"key\","
            + "\"literal\":\"\(secret)\","
            + "\"note\":\"\(nested)\","
            + "\"delta\":\"visible\"}\n\n"
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: secret)
        let output = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: output.frames, as: UTF8.self)

        XCTAssertFalse(emitted.contains(secret))
        XCTAssertFalse(emitted.contains("\\u0061b\\u0063"))
        let object = try XCTUnwrap(try decodeFrameObject(output.frames))
        XCTAssertFalse((object["note"] as? String)?.contains("u0061") == true)
        XCTAssertFalse(object.keys.contains(secret))
    }

    func testReasoningEventsBecomeFixedLivenessAndTerminalSnapshotsAreScrubbed() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let reasoning = "event: response.reasoning_summary_text.delta\n"
            + "data: {\"type\":\"response.reasoning_summary_text.delta\","
            + "\"delta\":\"private chain\",\"sequence_number\":9}\n\n"
        let liveness = try sanitizer.append(Data(reasoning.utf8))
        let livenessText = String(decoding: liveness.frames, as: UTF8.self)
        XCTAssertEqual(liveness.terminal, nil)
        XCTAssertTrue(livenessText.contains("response.in_progress"))
        XCTAssertFalse(livenessText.contains("private chain"))
        XCTAssertFalse(livenessText.contains("sequence_number"))

        let terminal = "data: {\"type\":\"response.incomplete\",\"response\":{"
            + "\"status\":\"incomplete\",\"output\":[{\"type\":\"reasoning\","
            + "\"id\":\"r1\",\"summary\":[\"private summary\"],"
            + "\"encrypted_content\":\"opaque\"}],"
            + "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"
        let result = try sanitizer.append(Data(terminal.utf8))
        let resultText = String(decoding: result.frames, as: UTF8.self)
        XCTAssertEqual(result.terminal, .incomplete)
        XCTAssertTrue(sanitizer.didReachTerminal)
        XCTAssertTrue(resultText.contains("response.incomplete"))
        XCTAssertTrue(resultText.contains("max_output_tokens"))
        XCTAssertTrue(resultText.contains("opaque"))
        XCTAssertFalse(resultText.contains("private summary"))
    }

    func testCompletedWithIncompleteStatusNormalizesAndSignalsTerminal() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "event: response.completed\n"
            + "data: {\"type\":\"response.completed\","
            + "\"response\":{\"status\":\"incomplete\",\"output\":[]}}\n\n"
        let result = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)

        XCTAssertEqual(result.terminal, .incomplete)
        XCTAssertTrue(emitted.contains("event: response.incomplete"))
        XCTAssertTrue(emitted.contains(#""type":"response.incomplete""#))
        XCTAssertThrowsError(try sanitizer.append(Data("data: [DONE]\n\n".utf8)))
    }

    func testCompletedWithFailedStatusNormalizesToFailure() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "event: response.completed\n"
            + "data: {\"type\":\"response.completed\","
            + "\"response\":{\"status\":\"failed\","
            + "\"error\":{\"message\":\"provider failure\"}}}\n\n"
        let result = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)

        XCTAssertEqual(result.terminal, .failed)
        XCTAssertTrue(emitted.contains("event: response.failed"))
        XCTAssertTrue(emitted.contains(#""type":"response.failed""#))
        XCTAssertFalse(emitted.contains("response.completed"))
    }

    func testTerminalTypesRequireMatchingKnownNestedStatus() throws {
        let invalidFrames = [
            "data: {\"type\":\"response.completed\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{}}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"queued\"}}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":7}}\n\n",
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"completed\"}}\n\n",
            "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"completed\"}}\n\n",
            "data: {\"type\":\"response.failed\",\"response\":{}}\n\n",
        ]

        for frame in invalidFrames {
            var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
            XCTAssertThrowsError(
                try sanitizer.append(Data(frame.utf8)),
                "Expected terminal mismatch to fail closed: \(frame)"
            )
        }

        var failed = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let validFailure = "data: {\"type\":\"response.failed\","
            + "\"response\":{\"status\":\"failed\"}}\n\n"
        XCTAssertEqual(
            try failed.append(Data(validFailure.utf8)).terminal,
            .failed
        )
    }

    func testReasoningFieldShapesAreEmptiedOrReducedToSafeScalars() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "data: {\"type\":\"response.completed\",\"response\":{"
            + "\"status\":\"completed\","
            + "\"reasoning\":{\"nested\":\"private object\"},"
            + "\"reasoning_summary\":[\"private array\"],"
            + "\"summary\":\"private scalar\","
            + "\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\","
            + "\"status\":\"completed\",\"summary\":{\"text\":\"private item\"},"
            + "\"content\":[\"private content\"],"
            + "\"encrypted_content\":{\"payload\":\"private malformed opaque\"}}]}}\n\n"

        let result = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)
        let object = try XCTUnwrap(try decodeFrameObject(result.frames))
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        let reasoningItem = try XCTUnwrap(output.first)

        XCTAssertEqual(result.terminal, .completed)
        XCTAssertTrue((response["reasoning"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue((response["reasoning_summary"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(response["summary"] as? String, "")
        XCTAssertEqual(reasoningItem["type"] as? String, "reasoning")
        XCTAssertEqual(reasoningItem["id"] as? String, "rs_1")
        XCTAssertEqual(reasoningItem["status"] as? String, "completed")
        XCTAssertEqual(reasoningItem["encrypted_content"] as? String, "")
        XCTAssertNil(reasoningItem["summary"])
        XCTAssertNil(reasoningItem["content"])
        XCTAssertFalse(emitted.contains("private"))
    }

    func testHiddenReasoningEventDropsNestedAndArrayPayloadShapes() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "event: response.reasoning_summary_text.delta\n"
            + "data: {\"type\":\"response.reasoning_summary_text.delta\","
            + "\"delta\":{\"text\":\"private nested\"},"
            + "\"summary\":[\"private array\"],\"sequence_number\":9}\n\n"

        let result = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)

        XCTAssertNil(result.terminal)
        XCTAssertTrue(emitted.contains("response.in_progress"))
        XCTAssertFalse(emitted.contains("private"))
        XCTAssertFalse(emitted.contains("sequence_number"))
    }

    func testAcceptsResponsesLifecycleDoneSnapshotsWithNestedItems() throws {
        // vLLM emits complete reasoning/message/function snapshots as
        // response.output_item.done events. Their metadata strings must not be
        // mistaken for an unknown append-only `.done` semantic stream.
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let reasoning = "event: response.output_item.done\n"
            + "data: {\"item\":{\"id\":\"r1\",\"type\":\"reasoning\","
            + "\"content\":[{\"text\":\"private\",\"type\":\"reasoning_text\"}],"
            + "\"encrypted_content\":null,\"status\":\"completed\"},"
            + "\"output_index\":0,\"type\":\"response.output_item.done\"}\n\n"
        let function = "event: response.output_item.done\n"
            + "data: {\"item\":{\"arguments\":\"{\\\"x\\\":1}\","
            + "\"call_id\":\"call_1\",\"name\":\"shell\","
            + "\"type\":\"function_call\",\"status\":\"completed\"},"
            + "\"output_index\":1,\"type\":\"response.output_item.done\"}\n\n"

        let first = try sanitizer.append(Data(reasoning.utf8))
        let second = try sanitizer.append(Data(function.utf8))
        let emitted = String(decoding: first.frames + second.frames, as: UTF8.self)

        XCTAssertTrue(emitted.contains("response.output_item.done"))
        XCTAssertTrue(emitted.contains("function_call"))
        XCTAssertFalse(emitted.contains("private"))
    }

    func testUnknownDoneSnapshotWithStringsStillFailsClosed() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "data: {\"type\":\"response.future_item.done\","
            + "\"id\":\"item_1\",\"text\":\"opaque\"}\n\n"
        XCTAssertThrowsError(try sanitizer.append(Data(frame.utf8)))
    }

    func testTerminalInSharedChunkStopsBeforeContradictoryLaterSuccess() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let incomplete = "data: {\"type\":\"response.incomplete\","
            + "\"response\":{\"status\":\"incomplete\"}}\n\n"
        let completed = "data: {\"type\":\"response.completed\","
            + "\"response\":{\"status\":\"completed\"}}\n\n"
        let result = try sanitizer.append(Data((incomplete + completed).utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)

        XCTAssertEqual(result.terminal, .incomplete)
        XCTAssertTrue(emitted.contains("response.incomplete"))
        XCTAssertFalse(emitted.contains("response.completed"))
    }

    func testPreservesIncompleteSemanticsAndLargeIntegers() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let frame = "data: {\"type\":\"response.incomplete\","
            + "\"sequence_number\":9223372036854775808,"
            + "\"response\":{\"status\":\"incomplete\","
            + "\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"
        let result = try sanitizer.append(Data(frame.utf8))
        let emitted = String(decoding: result.frames, as: UTF8.self)

        XCTAssertEqual(result.terminal, .incomplete)
        XCTAssertTrue(emitted.contains("9223372036854775808"))
        XCTAssertTrue(emitted.contains("max_output_tokens"))
    }

    func testRejectsMalformedDuplicateDepthOversizeAndUnterminatedData() throws {
        var duplicate = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        XCTAssertThrowsError(try duplicate.append(Data(
            "data: {\"type\":\"response.output_text.delta\","
                .appending("\"t\\u0079pe\":\"response.reasoning_text.delta\",\"delta\":\"x\"}\n\n")
                .utf8
        )))

        var mismatchedType = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        XCTAssertThrowsError(try mismatchedType.append(Data(
            "event: response.output_text.delta\n"
                .appending("data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"x\"}\n\n")
                .utf8
        )))

        var duplicateEventField = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        XCTAssertThrowsError(try duplicateEventField.append(Data(
            "event: response.output_text.delta\n"
                .appending("event: response.reasoning_text.delta\n")
                .appending("data: {\"type\":\"response.reasoning_text.delta\",\"delta\":\"x\"}\n\n")
                .utf8
        )))

        var depth = OpenAICompatibleResponsesSSESanitizer(
            credential: nil,
            limits: .init(maximumEventBytes: 1_024, maximumJSONDepth: 2)
        )
        XCTAssertThrowsError(try depth.append(Data(
            "data: {\"type\":\"response.output_text.delta\",\"x\":[[0]]}\n\n".utf8
        )))

        var oversized = OpenAICompatibleResponsesSSESanitizer(
            credential: nil,
            limits: .init(maximumEventBytes: 32)
        )
        XCTAssertThrowsError(try oversized.append(Data(
            "data: {\"type\":\"response.output_text.delta\"}\n\n".utf8
        )))

        var unterminated = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        _ = try unterminated.append(Data(
            "data: {\"type\":\"response.output_text.delta\"}".utf8
        ))
        XCTAssertThrowsError(try unterminated.finish())
    }

    func testFinishEmitsFinalCompleteFrameAndDoneIsTerminal() throws {
        var finalFrame = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        _ = try finalFrame.append(Data(
            "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"ok\"}\n".utf8
        ))
        let finished = try finalFrame.finish()
        XCTAssertTrue(String(decoding: finished.frames, as: UTF8.self).contains("ok"))

        var done = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        let result = try done.append(Data("data: [DONE]\n\n".utf8))
        XCTAssertEqual(result.terminal, .done)
    }

    func testOrdinaryJSONStringTextIsNotCanonicalized() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "unrelated")
        let assistantText = #"{ \"b\" : 2, \"a\" : 1 }"#
        let object: [String: Any] = [
            "type": "response.output_text.delta",
            "item_id": "msg_1",
            "output_index": 0,
            "content_index": 0,
            "delta": assistantText,
        ]
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var frame = Data("data: ".utf8)
        frame.append(payload)
        frame.append(Data("\n\n".utf8))

        let output = try sanitizer.append(frame)
        let decoded = try XCTUnwrap(try decodeFrameObject(output.frames))
        XCTAssertEqual(decoded["delta"] as? String, assistantText)
    }

    func testCrossEventCredentialIsWithheldAndRejectedBeforeEmission() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let first = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let second = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"ret\"}\n\n"

        let held = try sanitizer.append(Data(first.utf8))
        XCTAssertTrue(held.frames.isEmpty)
        XCTAssertFalse(held.canFlushDownstream)
        XCTAssertThrowsError(try sanitizer.append(Data(second.utf8)))
    }

    func testUnicodeScalarCredentialSplitAcrossEventsFailsBeforeEmission() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "🔐key")
        let first = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"u1\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"🔐\"}\n\n"
        let second = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"u1\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"key\"}\n\n"

        XCTAssertTrue(try sanitizer.append(Data(first.utf8)).frames.isEmpty)
        XCTAssertThrowsError(try sanitizer.append(Data(second.utf8)))
    }

    func testCredentialPrefixIsReleasedWhenLaterDeltaDisambiguatesIt() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let first = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let second = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"tion\"}\n\n"

        let held = try sanitizer.append(Data(first.utf8))
        XCTAssertTrue(held.frames.isEmpty)
        let released = try sanitizer.append(Data(second.utf8))
        let text = String(decoding: released.frames, as: UTF8.self)
        XCTAssertTrue(released.canFlushDownstream)
        XCTAssertTrue(text.contains(#""delta":"sec""#))
        XCTAssertTrue(text.contains(#""delta":"tion""#))
    }

    func testWithheldPrefixKeepsInterveningEventsInOrder() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let prefix = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let progress = "data: {\"type\":\"response.in_progress\",\"response\":{}}\n\n"
        let disambiguating = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"tion\"}\n\n"

        XCTAssertTrue(try sanitizer.append(Data(prefix.utf8)).frames.isEmpty)
        XCTAssertTrue(try sanitizer.append(Data(progress.utf8)).frames.isEmpty)
        let released = try sanitizer.append(Data(disambiguating.utf8)).frames
        let text = String(decoding: released, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: #""delta":"sec""#)?.lowerBound),
                          try XCTUnwrap(text.range(of: "response.in_progress")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "response.in_progress")?.lowerBound),
                          try XCTUnwrap(text.range(of: #""delta":"tion""#)?.lowerBound))
    }

    func testFunctionArgumentsBufferUntilMatchingDoneAndRejectEscapedCredential() throws {
        var safe = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let safeDelta = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call_1\",\"output_index\":0,\"delta\":\"{\\\"x\\\":1}\"}\n\n"
        let safeDone = "data: {\"type\":\"response.function_call_arguments.done\","
            + "\"item_id\":\"call_1\",\"output_index\":0,\"arguments\":\"{\\\"x\\\":1}\"}\n\n"
        XCTAssertTrue(try safe.append(Data(safeDelta.utf8)).frames.isEmpty)
        let released = try safe.append(Data(safeDone.utf8))
        XCTAssertTrue(released.canFlushDownstream)
        XCTAssertTrue(String(decoding: released.frames, as: UTF8.self).contains("call_1"))

        var leaking = OpenAICompatibleResponsesSSESanitizer(credential: "abc")
        let first = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call_2\",\"output_index\":0,\"delta\":\"\\\\u00\"}\n\n"
        let second = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call_2\",\"output_index\":0,\"delta\":\"61bc\"}\n\n"
        XCTAssertTrue(try leaking.append(Data(first.utf8)).frames.isEmpty)
        XCTAssertThrowsError(try leaking.append(Data(second.utf8)))

        var mismatch = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        XCTAssertTrue(try mismatch.append(Data(safeDelta.utf8)).frames.isEmpty)
        let badDone = safeDone.replacingOccurrences(of: "{\\\"x\\\":1}", with: "{\\\"x\\\":2}")
        XCTAssertThrowsError(try mismatch.append(Data(badDone.utf8)))
    }

    func testInterleavedStreamsCannotSplitCredentialAndDoneThenDeltaFailsClosed() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let a = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let b = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"b\","
            + "\"output_index\":1,\"content_index\":0,\"delta\":\"ret\"}\n\n"
        XCTAssertTrue(try sanitizer.append(Data(a.utf8)).frames.isEmpty)
        XCTAssertThrowsError(try sanitizer.append(Data(b.utf8)))

        var benign = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        XCTAssertTrue(try benign.append(Data(a.utf8)).frames.isEmpty)
        let other = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"b\","
            + "\"output_index\":1,\"content_index\":0,\"delta\":\"tion\"}\n\n"
        XCTAssertTrue(try benign.append(Data(other.utf8)).frames.isEmpty)
        let aContinuation = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"tion\"}\n\n"
        let released = try benign.append(Data(aContinuation.utf8))
        let releasedText = String(decoding: released.frames, as: UTF8.self)
        XCTAssertTrue(releasedText.contains("\"item_id\":\"a\""))
        XCTAssertTrue(releasedText.contains("\"item_id\":\"b\""))

        var lifecycle = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let done = "data: {\"type\":\"response.output_text.done\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"text\":\"ok\"}\n\n"
        let late = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"late\"}\n\n"
        _ = try lifecycle.append(Data(done.utf8))
        XCTAssertThrowsError(try lifecycle.append(Data(late.utf8)))
    }

    func testTextAndRefusalShareOneOrderedCredentialBoundary() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let text = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let refusal = "data: {\"type\":\"response.refusal.delta\",\"item_id\":\"b\","
            + "\"output_index\":1,\"content_index\":0,\"delta\":\"ret\"}\n\n"

        XCTAssertTrue(try sanitizer.append(Data(text.utf8)).frames.isEmpty)
        XCTAssertThrowsError(try sanitizer.append(Data(refusal.utf8)))
    }

    func testSeparateFunctionCallsCannotSplitCredentialAcrossItemIDs() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let first = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call_a\",\"output_index\":0,\"delta\":\"sec\"}\n\n"
        let second = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call_b\",\"output_index\":1,\"delta\":\"ret\"}\n\n"

        XCTAssertTrue(try sanitizer.append(Data(first.utf8)).frames.isEmpty)
        XCTAssertThrowsError(try sanitizer.append(Data(second.utf8)))
    }

    func testRefusalUsesIndependentIdentityAndBenignDoneFlushesHeldPrefix() throws {
        var refusal = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let prefix = "data: {\"type\":\"response.refusal.delta\",\"item_id\":\"r1\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let done = "data: {\"type\":\"response.refusal.done\",\"item_id\":\"r1\","
            + "\"output_index\":0,\"content_index\":0,\"refusal\":\"section\"}\n\n"
        XCTAssertTrue(try refusal.append(Data(prefix.utf8)).frames.isEmpty)
        let released = try refusal.append(Data(done.utf8)).frames
        XCTAssertTrue(String(decoding: released, as: UTF8.self).contains("section"))

        var unfinished = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let text = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"t1\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let terminal = "data: {\"type\":\"response.completed\","
            + "\"response\":{\"status\":\"completed\"}}\n\n"
        _ = try unfinished.append(Data(text.utf8))
        let completed = try unfinished.append(Data(terminal.utf8))
        XCTAssertEqual(completed.terminal, .completed)
        XCTAssertTrue(String(decoding: completed.frames, as: UTF8.self).contains("\"delta\":\"sec\""))
    }

    func testMissingChangedIdentityAndAggregateBoundsFailClosed() throws {
        let missing = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\n\n"
        var noIdentity = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        XCTAssertThrowsError(try noIdentity.append(Data(missing.utf8)))

        var changed = OpenAICompatibleResponsesSSESanitizer(credential: "secret")
        let first = "data: {\"type\":\"response.function_call_arguments.delta\","
            + "\"item_id\":\"call\",\"output_index\":0,\"delta\":\"{}\"}\n\n"
        let done = "data: {\"type\":\"response.function_call_arguments.done\","
            + "\"item_id\":\"call\",\"output_index\":1,\"arguments\":\"{}\"}\n\n"
        _ = try changed.append(Data(first.utf8))
        XCTAssertThrowsError(try changed.append(Data(done.utf8)))

        let tight = OpenAICompatibleResponsesSSESanitizer.Limits(
            maximumEventBytes: 2_048,
            maximumSemanticStreams: 1,
            maximumIdentifierBytes: 3,
            maximumRetainedSemanticBytes: 5
        )
        var identifier = OpenAICompatibleResponsesSSESanitizer(credential: "secret", limits: tight)
        let longID = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"long\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"x\"}\n\n"
        XCTAssertThrowsError(try identifier.append(Data(longID.utf8)))

        let aggregateLimits = OpenAICompatibleResponsesSSESanitizer.Limits(
            maximumEventBytes: 2_048,
            maximumSemanticStreams: 3,
            maximumIdentifierBytes: 3,
            maximumRetainedSemanticBytes: 5
        )
        var aggregate = OpenAICompatibleResponsesSSESanitizer(credential: "secret", limits: aggregateLimits)
        let a = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"a\","
            + "\"output_index\":0,\"content_index\":0,\"delta\":\"sec\"}\n\n"
        let b = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"b\","
            + "\"output_index\":1,\"content_index\":0,\"delta\":\"se\"}\n\n"
        let c = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"c\","
            + "\"output_index\":2,\"content_index\":0,\"delta\":\"s\"}\n\n"
        _ = try aggregate.append(Data(a.utf8))
        _ = try aggregate.append(Data(b.utf8))
        XCTAssertThrowsError(try aggregate.append(Data(c.utf8)))
    }

    func testRemovingEscapedCredentialDoesNotConsumeAdjacentText() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: "abc")
        let frame = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,"
            + "\"delta\":\"before \\u0061bc after\"}\n\n"
        let output = try sanitizer.append(Data(frame.utf8))
        let object = try XCTUnwrap(try decodeFrameObject(output.frames))

        XCTAssertEqual(object["delta"] as? String, "before  after")
    }

    func testLargeEscapedPayloadRedactsWithoutUnboundedSourceIndexSets() throws {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(
            credential: "abc",
            limits: .init(maximumEventBytes: 512 * 1_024)
        )
        let prefix = String(repeating: "visible-", count: 8_000)
        let frame = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"large\","
            + "\"output_index\":0,\"content_index\":0,"
            + "\"delta\":\"\(prefix)\\u0061bc-tail\"}\n\n"
        let output = try sanitizer.append(Data(frame.utf8))
        let object = try XCTUnwrap(try decodeFrameObject(output.frames))
        let delta = try XCTUnwrap(object["delta"] as? String)

        XCTAssertTrue(delta.hasPrefix(prefix))
        XCTAssertTrue(delta.hasSuffix("-tail"))
        XCTAssertFalse(delta.contains("abc"))
    }

    private func sanitize(
        _ data: Data,
        chunkSizes: [Int]
    ) throws -> OpenAICompatibleResponsesSSESanitizer.Output {
        var sanitizer = OpenAICompatibleResponsesSSESanitizer(credential: nil)
        var frames = Data()
        var terminal: OpenAICompatibleResponsesSSESanitizer.Terminal?
        var canFlushDownstream = true
        var offset = 0
        for size in chunkSizes where offset < data.count {
            let end = min(data.count, offset + max(1, size))
            let output = try sanitizer.append(data[offset ..< end])
            frames.append(output.frames)
            terminal = output.terminal ?? terminal
            canFlushDownstream = output.canFlushDownstream
            offset = end
        }
        if offset < data.count {
            let output = try sanitizer.append(data[offset...])
            frames.append(output.frames)
            terminal = output.terminal ?? terminal
            canFlushDownstream = output.canFlushDownstream
        }
        return .init(
            frames: frames,
            terminal: terminal,
            canFlushDownstream: canFlushDownstream
        )
    }

    private func decodeFrameObject(_ frame: Data) throws -> [String: Any]? {
        let text = String(decoding: frame, as: UTF8.self)
        guard let dataLine = text.split(separator: "\n").first(where: {
            $0.hasPrefix("data: ")
        }) else { return nil }
        let payload = dataLine.dropFirst("data: ".count)
        return try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    }
}
