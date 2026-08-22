import AppKit
import XCTest
@testable import Onyx

final class ComposerImageInputTests: XCTestCase {
    func testPastedImageProducesBoundedPNGDataURLInput() throws {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()

        let draft = try ComposerImageValidator.pastedImage(image)

        guard case let .imageURL(url) = draft.input else {
            return XCTFail("Pasted images must use an image URL turn input")
        }
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        XCTAssertGreaterThan(draft.byteCount, 0)
        XCTAssertLessThanOrEqual(draft.byteCount, ComposerImageValidator.maximumBytes)
    }

    func testUnsupportedAndCorruptLocalFilesFailWithClearValidationErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerImageInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let unsupported = directory.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: unsupported)
        XCTAssertThrowsError(try ComposerImageValidator.localFile(at: unsupported)) { error in
            XCTAssertEqual(error as? ComposerImageValidationError, .unsupported("notes.txt"))
        }

        let corrupt = directory.appendingPathComponent("broken.png")
        try Data("not actually png".utf8).write(to: corrupt)
        XCTAssertThrowsError(try ComposerImageValidator.localFile(at: corrupt)) { error in
            XCTAssertEqual(error as? ComposerImageValidationError, .unreadable("broken.png"))
        }
    }

    func testOversizedLocalFileIsRejectedBeforeImageDecode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: ComposerImageValidator.maximumBytes + 1).write(to: url)

        XCTAssertThrowsError(try ComposerImageValidator.localFile(at: url)) { error in
            XCTAssertEqual(
                error as? ComposerImageValidationError,
                .tooLarge(url.lastPathComponent, maximumMegabytes: 20)
            )
        }
    }

    func testTurnRequestPreservesMixedInputOrderAndTextCompatibility() {
        let request = StartTurnRequest(
            threadID: "mixed-input",
            inputs: [
                .localImagePath("/tmp/first.png"),
                .text("between"),
                .imageURL("https://example.com/last.jpg"),
            ]
        )

        XCTAssertEqual(request.inputs, [
            .localImagePath("/tmp/first.png"),
            .text("between"),
            .imageURL("https://example.com/last.jpg"),
        ])
        XCTAssertEqual(request.text, "between")
        XCTAssertEqual(StartTurnRequest(threadID: "text", text: "legacy").inputs, [.text("legacy")])
    }
}
