import Foundation
import XCTest
@testable import Onyx

final class JSONLFramerTests: XCTestCase {
    func testFramesLinesAcrossArbitraryChunkBoundariesWithoutCorruptingUTF8() throws {
        let payload = "{\"text\":\"onyx ◆\"}\n{\"value\":2}\n"
        let bytes = Data(payload.utf8)

        for split in 0 ... bytes.count {
            var framer = JSONLFramer()
            let first = try framer.append(Data(bytes.prefix(split)))
            let second = try framer.append(Data(bytes.dropFirst(split)))
            let lines = (first + second).map { String(decoding: $0, as: UTF8.self) }

            XCTAssertEqual(lines, ["{\"text\":\"onyx ◆\"}", "{\"value\":2}"])
            XCTAssertEqual(framer.bytesInspected, bytes.count)
        }
    }

    func testLargeNewlineFreeMessageIsInspectedOnceAcrossSingleByteChunks() throws {
        var framer = JSONLFramer()
        let body = Data(repeating: 0x61, count: 100_000)

        for byte in body {
            XCTAssertTrue(try framer.append(Data([byte])).isEmpty)
        }
        XCTAssertEqual(framer.bytesInspected, body.count)

        let lines = try framer.append(Data([0x0A]))
        XCTAssertEqual(lines, [body])
        XCTAssertEqual(framer.bytesInspected, body.count + 1)
    }

    func testResetDropsPartialDataAndRestartsInstrumentation() throws {
        var framer = JSONLFramer()
        XCTAssertTrue(try framer.append(Data("stale".utf8)).isEmpty)

        framer.reset()

        XCTAssertEqual(try framer.append(Data("fresh\n".utf8)), [Data("fresh".utf8)])
        XCTAssertEqual(framer.bytesInspected, 6)
    }

    func testRecordLimitAllowsTheBoundaryAndRejectsTheNextByte() throws {
        var framer = JSONLFramer(maximumRecordBytes: 8)
        let boundary = Data(repeating: 0x61, count: 8)

        XCTAssertTrue(try framer.append(boundary).isEmpty)
        XCTAssertEqual(try framer.append(Data([0x0A])), [boundary])

        XCTAssertTrue(try framer.append(boundary).isEmpty)
        XCTAssertThrowsError(try framer.append(Data([0x62]))) { error in
            XCTAssertEqual(error as? JSONLFramerError, .recordTooLarge(limit: 8))
        }

        XCTAssertEqual(try framer.append(Data("ok\n".utf8)), [Data("ok".utf8)])
    }
}
