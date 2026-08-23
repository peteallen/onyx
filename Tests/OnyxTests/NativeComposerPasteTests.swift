import AppKit
import XCTest
@testable import Onyx

@MainActor
final class NativeComposerPasteTests: XCTestCase {
    func testNativePasteRoutesScreenshotDataToImageHandler() throws {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(try makePNG(), forType: .png))

        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.string = "Keep the existing prompt"
        textView.pastedImagesProvider = {
            ComposerPasteboardImages.images(from: [item])
        }
        var pastedImages: [NSImage] = []
        textView.onPasteImages = { pastedImages = $0 }

        textView.paste(nil)

        XCTAssertEqual(pastedImages.count, 1)
        let pastedImage = try XCTUnwrap(pastedImages.first)
        XCTAssertEqual(pastedImage.size.width, 10, accuracy: 0.01)
        XCTAssertEqual(pastedImage.size.height, 6, accuracy: 0.01)
        XCTAssertEqual(
            textView.string,
            "Keep the existing prompt",
            "Pasting an image must attach it without inserting clipboard data into the prompt"
        )
    }

    func testReadsScreenshotStylePNGDataFromPasteboard() throws {
        let item = NSPasteboardItem()
        let data = try makePNG()
        XCTAssertTrue(item.setData(data, forType: .png))

        let images = try XCTUnwrap(ComposerPasteboardImages.images(from: [item]))

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].size.width, 10, accuracy: 0.01)
        XCTAssertEqual(images[0].size.height, 6, accuracy: 0.01)
    }

    func testReadsCopiedImageFileURLFromPasteboard() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnyxComposerPasteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("copied-image.png")
        try makePNG().write(to: imageURL)

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(imageURL.absoluteString, forType: .fileURL))

        let images = try XCTUnwrap(ComposerPasteboardImages.images(from: [item]))

        XCTAssertEqual(images.count, 1)
    }

    func testReturnsNilForPlainTextClipboard() {
        let item = NSPasteboardItem()
        item.setString("keep this as ordinary composer text", forType: .string)

        XCTAssertNil(ComposerPasteboardImages.images(from: [item]))
    }

    private func makePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
