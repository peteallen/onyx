import AppKit
import XCTest
@testable import Onyx

final class TranscriptAttachmentTests: XCTestCase {
    func testDataURLDecoderAcceptsImageBase64AndRejectsOtherPayloads() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let url = "data:image/png;base64,\(bytes.base64EncodedString())"

        XCTAssertEqual(try TranscriptImageLoader.decodeImageDataURL(url), bytes)
        XCTAssertThrowsError(try TranscriptImageLoader.decodeImageDataURL("data:text/plain;base64,SGVsbG8="))
        XCTAssertThrowsError(try TranscriptImageLoader.decodeImageDataURL("data:image/png,not-base64"))
        XCTAssertThrowsError(try TranscriptImageLoader.decodeImageDataURL("data:image/png;base64,%%%"))

        let fourBytes = Data([0, 1, 2, 3]).base64EncodedString()
        XCTAssertThrowsError(
            try TranscriptImageLoader.decodeImageDataURL(
                "data:image/png;base64,\(fourBytes)",
                maximumDecodedBytes: 3
            )
        )
    }

    func testRemoteResponseAndStreamingBoundsAllowTheLimitButRejectTheNextByte() throws {
        XCTAssertNoThrow(
            try TranscriptImageLoader.validateExpectedContentLength(2, maximumBytes: 2)
        )
        XCTAssertThrowsError(
            try TranscriptImageLoader.validateExpectedContentLength(3, maximumBytes: 2)
        )
        XCTAssertNoThrow(
            try TranscriptImageLoader.validateExpectedContentLength(-1, maximumBytes: 2),
            "Unknown content length is bounded by the byte loop instead"
        )

        var data = Data()
        try TranscriptImageLoader.appendRemoteByte(1, to: &data, maximumBytes: 2)
        try TranscriptImageLoader.appendRemoteByte(2, to: &data, maximumBytes: 2)
        XCTAssertEqual(data.count, 2)
        XCTAssertThrowsError(
            try TranscriptImageLoader.appendRemoteByte(3, to: &data, maximumBytes: 2)
        )
    }

    func testDownsampleBoundsLargeImageWithoutKeepingOriginalDimensions() throws {
        let sourceImage = NSImage(size: NSSize(width: 1_600, height: 800))
        sourceImage.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1_600, height: 800)).fill()
        sourceImage.unlockFocus()
        let tiff = try XCTUnwrap(sourceImage.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let representation = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        let thumbnail = try TranscriptImageLoader.downsample(data: representation, maximumPixelSize: 320)

        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 320)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 2, accuracy: 0.02)
    }

    @MainActor
    func testTranscriptHeightReservesBoundedAttachmentGrid() {
        let attachment = TimelineAttachment(
            id: "image",
            source: .localFilePath("/tmp/image.png"),
            accessibilityLabel: "Image"
        )
        let plain = TimelineItem(
            id: "plain",
            kind: .assistantMessage,
            title: nil,
            body: "Result",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        var one = plain
        one.attachments = [attachment]
        var many = plain
        many.attachments = (0..<8).map { index in
            TimelineAttachment(
                id: "image-\(index)",
                source: .localFilePath("/tmp/image-\(index).png"),
                accessibilityLabel: "Image \(index)"
            )
        }

        let plainHeight = TranscriptCellView.height(for: plain, width: 640)
        let oneHeight = TranscriptCellView.height(for: one, width: 640)
        let manyHeight = TranscriptCellView.height(for: many, width: 640)

        XCTAssertGreaterThan(oneHeight, plainHeight + 100)
        XCTAssertGreaterThan(manyHeight, oneHeight)

        var exactlyVisible = plain
        exactlyVisible.attachments = Array(many.attachments.prefix(TranscriptCellView.maximumVisibleAttachments))
        XCTAssertEqual(
            manyHeight,
            TranscriptCellView.height(for: exactlyVisible, width: 640),
            accuracy: 0.5,
            "Extra media should not grow recycled transcript cells without bound"
        )
    }

    @MainActor
    func testTranscriptHeightReservesBoundedResourceLinkRows() {
        let plain = TimelineItem(
            id: "plain-links",
            kind: .tool,
            title: "Search",
            body: "Results",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        var linked = plain
        linked.links = (0..<8).map { index in
            TimelineResourceLink(
                id: "link-" + String(index),
                title: "Reference " + String(index),
                url: URL(string: "https://example.test/" + String(index))!,
                detail: "example.test"
            )
        }

        let plainHeight = TranscriptCellView.height(for: plain, width: 640)
        let linkedHeight = TranscriptCellView.height(for: linked, width: 640)
        XCTAssertGreaterThan(linkedHeight, plainHeight + 150)

        var exactlyVisible = plain
        exactlyVisible.links = Array(linked.links.prefix(TranscriptCellView.maximumVisibleLinks))
        XCTAssertEqual(
            linkedHeight,
            TranscriptCellView.height(for: exactlyVisible, width: 640),
            accuracy: 0.5,
            "Extra resource links should not grow recycled transcript cells without bound"
        )
    }

    @MainActor
    func testResourceLinkViewIsAccessibleAndHasNativeLinkRole() {
        let link = TimelineResourceLink(
            id: "accessible-link",
            title: "Open guide",
            url: URL(string: "https://docs.example.test/guide")!,
            detail: "docs.example.test"
        )

        let view = TranscriptResourceLinkView(link: link)

        XCTAssertEqual(view.accessibilityRole(), .link)
        XCTAssertEqual(view.accessibilityLabel(), "Open Open guide")
        XCTAssertEqual(view.accessibilityValue() as? String, "https://docs.example.test/guide")
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    @MainActor
    func testPreparingCellForReuseRemovesResourceLinkViews() {
        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        let baselineSubviewCount = cell.subviews.count
        var item = TimelineItem(
            id: "linked-cell",
            kind: .tool,
            title: "Lookup",
            body: "Returned a link.",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        item.links = [
            TimelineResourceLink(
                id: "link",
                title: "Guide",
                url: URL(string: "https://docs.example.test/guide")!
            ),
        ]

        cell.configure(with: item)
        XCTAssertEqual(cell.subviews.count, baselineSubviewCount + 1)
        XCTAssertEqual(cell.subviews.last?.accessibilityRole(), .link)

        cell.prepareForReuse()
        XCTAssertEqual(cell.subviews.count, baselineSubviewCount)
    }

    @MainActor
    func testPreparingCellForReuseRemovesAttachmentViews() throws {
        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let baselineSubviewCount = cell.subviews.count
        let attachment = TimelineAttachment(
            id: "image",
            source: .localFilePath("/tmp/image-that-does-not-need-to-exist.png"),
            accessibilityLabel: "Image"
        )
        let item = TimelineItem(
            id: "item",
            kind: .assistantMessage,
            title: nil,
            body: "Result",
            status: .completed,
            timestamp: .now,
            detail: nil,
            attachments: [attachment]
        )

        cell.configure(with: item)
        XCTAssertEqual(cell.subviews.count, baselineSubviewCount + 1)
        let oldAttachmentView = try XCTUnwrap(cell.subviews.last)
        XCTAssertEqual(oldAttachmentView.accessibilityRole(), .button)
        XCTAssertTrue(oldAttachmentView.acceptsFirstResponder)

        let replacement = TimelineItem(
            id: "replacement",
            kind: .assistantMessage,
            title: nil,
            body: "Replacement",
            status: .completed,
            timestamp: .now,
            detail: nil,
            attachments: [
                TimelineAttachment(
                    id: "replacement-image",
                    source: .localFilePath("/tmp/replacement.png"),
                    accessibilityLabel: "Replacement image"
                ),
            ]
        )
        cell.configure(with: replacement)
        XCTAssertNil(oldAttachmentView.superview, "A late completion has no reused cell content to mutate")
        XCTAssertEqual(cell.subviews.count, baselineSubviewCount + 1)

        cell.prepareForReuse()
        XCTAssertEqual(cell.subviews.count, baselineSubviewCount)
    }

    @MainActor
    func testDetachedAttachmentViewDeallocatesWhileThumbnailLoadIsSuspended() async {
        let started = AsyncStream.makeStream(of: Void.self)
        let loadGate = AsyncStream.makeStream(of: Void.self)
        let attachment = TimelineAttachment(
            id: "image",
            source: .localFilePath("/tmp/suspended-image.png"),
            accessibilityLabel: "Image"
        )
        var view: TranscriptAttachmentView? = TranscriptAttachmentView(
            attachment: attachment,
            thumbnailLoader: { _, _, _ in
                started.continuation.yield(())
                for await _ in loadGate.stream {}
                throw CancellationError()
            }
        )
        weak let weakView = view
        var startedIterator = started.stream.makeAsyncIterator()

        _ = await startedIterator.next()
        view = nil

        XCTAssertNil(
            weakView,
            "A suspended thumbnail request must not retain a transcript row removed by reuse"
        )
        loadGate.continuation.finish()
        started.continuation.finish()
    }
}
