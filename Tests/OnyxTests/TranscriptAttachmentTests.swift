import AppKit
import XCTest
@testable import Onyx

final class TranscriptAttachmentTests: XCTestCase {
    func testPendingResponseStaysInTranscriptUntilAssistantTextBeginsStreaming() {
        let user = TimelineItem(
            id: "pending-user",
            kind: .userMessage,
            title: nil,
            body: "Please take a look",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        var assistant = TimelineItem(
            id: "pending-assistant",
            kind: .assistantMessage,
            title: nil,
            body: "",
            status: .running,
            timestamp: .now,
            detail: nil
        )

        XCTAssertTrue(
            TranscriptPendingResponse.resolve(
                items: [user],
                isAwaitingResponse: true,
                label: "Working on a response…"
            ).isVisible
        )
        XCTAssertTrue(
            TranscriptPendingResponse.resolve(
                items: [user, assistant],
                isAwaitingResponse: true,
                label: "Working on a response…"
            ).isVisible,
            "An empty provider placeholder is not yet a visible response"
        )

        assistant.body = "I’m checking that now."
        XCTAssertFalse(
            TranscriptPendingResponse.resolve(
                items: [user, assistant],
                isAwaitingResponse: true,
                label: "Working on a response…"
            ).isVisible,
            "The inline indicator should yield to the streaming assistant message"
        )
        XCTAssertFalse(
            TranscriptPendingResponse.resolve(
                items: [user],
                isAwaitingResponse: false,
                label: "Working on a response…"
            ).isVisible
        )
    }

    @MainActor
    func testShortUserMessageUsesACompactNeutralBubbleAndAssistantKeepsReadableMeasure() {
        let user = TimelineItem(
            id: "compact-user",
            kind: .userMessage,
            title: nil,
            body: "hi",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let assistant = TimelineItem(
            id: "readable-assistant",
            kind: .assistantMessage,
            title: nil,
            body: "Hello — what should we work on?",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let userMetrics = TranscriptCellView.metrics(for: user, width: 720, isExpanded: true)
        let assistantMetrics = TranscriptCellView.metrics(for: assistant, width: 720, isExpanded: true)

        XCTAssertLessThan(userMetrics.contentWidth, assistantMetrics.contentWidth / 2)
        XCTAssertGreaterThan(userMetrics.contentX, assistantMetrics.contentX)
        XCTAssertLessThanOrEqual(assistantMetrics.contentWidth, 680)

        let height = TranscriptCellView.height(for: user, width: 720, isExpanded: true)
        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 720, height: height))
        cell.configure(with: user, isExpanded: true)
        cell.layout()
        XCTAssertLessThan(cell.messageBubbleFrame.width, 180)
        XCTAssertGreaterThan(cell.messageBubbleFrame.minX, 500)
        XCTAssertEqual(cell.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    @MainActor
    func testAssistantProtocolPhaseIsNotRenderedAsConversationMetadata() {
        var assistant = TimelineItem(
            id: "assistant-phase",
            kind: .assistantMessage,
            title: nil,
            body: "Finished the requested change.",
            status: .completed,
            timestamp: .now,
            detail: "final_answer"
        )
        XCTAssertEqual(TranscriptCellView.visibleDetail(for: assistant), "")

        assistant.detail = "Commentary"
        XCTAssertEqual(TranscriptCellView.visibleDetail(for: assistant), "")

        assistant.detail = "1,024 input tokens"
        XCTAssertEqual(TranscriptCellView.visibleDetail(for: assistant), "1,024 input tokens")
    }

    @MainActor
    func testRoutineActivityStartsAsASlimBorderlessRowAndTogglesWithAnAccessibleDisclosureControl() throws {
        var callbacks: [Bool] = []
        let item = TimelineItem(
            id: "compact-tool",
            kind: .tool,
            title: "Search files",
            body: "first result\n" + String(repeating: "additional verbose result ", count: 80),
            status: .completed,
            timestamp: .now,
            detail: "Search provider",
            links: [
                TimelineResourceLink(
                    id: "result",
                    title: "Open result",
                    url: URL(string: "https://example.test/result")!
                ),
            ]
        )
        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        cell.configure(with: item, isExpanded: false, onToggle: { callbacks.append($0) })

        XCTAssertFalse(cell.isExpanded)
        let collapsedMetrics = TranscriptCellView.metrics(for: item, width: 640, isExpanded: false)
        XCTAssertGreaterThan(collapsedMetrics.titleHeight, 0, "Collapsed activity keeps its title")
        XCTAssertEqual(collapsedMetrics.summaryHeight, 0, "Routine activity stays on one compact line")
        XCTAssertEqual(collapsedMetrics.statusWidth, 0, "Completed routine activity does not repeat a Done badge")
        XCTAssertLessThanOrEqual(
            TranscriptCellView.height(for: item, width: 640, isExpanded: false),
            36,
            "Collapsed routine activity should read like a compact log row, not a message card"
        )
        XCTAssertEqual(
            collapsedMetrics.detailHeight,
            0,
            "Collapsed activity must not repeat verbose provider metadata"
        )
        let renderedLabels = cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(renderedLabels.contains { $0.contains("Search files") })
        XCTAssertTrue(renderedLabels.contains { $0.contains("first result") })
        XCTAssertFalse(renderedLabels.contains("Done"))
        XCTAssertFalse(renderedLabels.contains("Search provider"))
        XCTAssertEqual(cell.layer?.borderWidth, 0)
        XCTAssertEqual(cell.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(cell.expansionControl.accessibilityRole(), .button)
        XCTAssertEqual(cell.expansionControl.accessibilityValue() as? String, "Collapsed")
        XCTAssertTrue(cell.expansionControl.accessibilityLabel()?.contains("Expand") == true)
        XCTAssertEqual(cell.subviews.filter { $0 is TranscriptResourceLinkView }.count, 0)
        cell.frame.size.height = TranscriptCellView.height(for: item, width: 640, isExpanded: false)
        cell.layout()
        let headerPoint = NSPoint(x: 120, y: cell.bounds.maxY - 8)
        XCTAssertTrue(
            cell.hitTest(headerPoint) === cell,
            "The whole compact header should be a click target, not only the chevron"
        )
        XCTAssertFalse(
            cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains(item.body),
            "Collapsed activity must not allocate its complete hidden payload"
        )

        let headerClick = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: headerPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        cell.mouseDown(with: headerClick)

        XCTAssertTrue(cell.isExpanded)
        XCTAssertEqual(callbacks, [true])
        XCTAssertEqual(cell.expansionControl.accessibilityValue() as? String, "Expanded")
        XCTAssertEqual(cell.subviews.filter { $0 is TranscriptResourceLinkView }.count, 1)
        XCTAssertTrue(
            cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains(item.body),
            "Expanding should materialize the complete original payload"
        )

        cell.toggleExpansion()
        XCTAssertFalse(cell.isExpanded)
        XCTAssertEqual(callbacks, [true, false])
        XCTAssertEqual(cell.subviews.filter { $0 is TranscriptResourceLinkView }.count, 0)
    }

    @MainActor
    func testRoutineActivityShowsOnlyLiveOrExceptionalStatusWhileActionableRowsStayProminent() {
        let running = TimelineItem(
            id: "running-command",
            kind: .command,
            title: "Run tests",
            body: "swift test",
            status: .running,
            timestamp: .now,
            detail: nil
        )
        let runningMetrics = TranscriptCellView.metrics(for: running, width: 640, isExpanded: false)
        XCTAssertGreaterThan(runningMetrics.statusWidth, 0)

        let runningCell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 36))
        runningCell.configure(with: running, isExpanded: false)
        let runningLabels = runningCell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(runningLabels.contains("Running"))
        XCTAssertGreaterThan(runningCell.layer?.borderWidth ?? 0, 0)
        XCTAssertNotEqual(runningCell.layer?.backgroundColor, NSColor.clear.cgColor)

        let failure = TimelineItem(
            id: "tool-failure",
            kind: .error,
            title: "Command failed",
            body: "The build exited with status 1.",
            status: .failed,
            timestamp: .now,
            detail: nil
        )
        let failureCell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 72))
        failureCell.configure(with: failure, isExpanded: true)
        XCTAssertGreaterThan(failureCell.layer?.borderWidth ?? 0, 0)
        XCTAssertNotEqual(failureCell.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    @MainActor
    func testCompactSummaryIsOneLineAndKeepsTheFirstUsefulText() {
        let item = TimelineItem(
            id: "summary",
            kind: .command,
            title: nil,
            body: "  command completed  \nsecond line should stay hidden",
            status: .completed,
            timestamp: .now,
            detail: nil
        )

        XCTAssertEqual(TranscriptCellView.compactSummary(for: item), "command completed")

        var long = item
        long.body = String(repeating: "x", count: 400)
        let summary = TranscriptCellView.compactSummary(for: long)
        XCTAssertEqual(summary.count, 180)
        XCTAssertTrue(summary.hasSuffix("…"))

        var markdown = item
        markdown.kind = .reasoning
        markdown.body = "\n## **Built** the [preview](https://example.test)"
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: markdown),
            "Built the preview",
            "Compact activity should not expose Markdown punctuation"
        )
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: markdown, maximumCharacters: 1),
            "B"
        )

        var addedLine = item
        addedLine.body = "+ added.swift"
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: addedLine),
            "+ added.swift",
            "Collapsed command and diff previews must preserve literal evidence markers"
        )

        var removedLine = item
        removedLine.kind = .fileChange
        removedLine.body = "- removed.swift"
        XCTAssertEqual(TranscriptCellView.compactSummary(for: removedLine), "- removed.swift")
    }

    @MainActor
    func testPlanStartsAsAQuietProgressLineAndExpandsOnDemand() {
        let plan = TimelineItem(
            id: "active-plan",
            kind: .plan,
            title: "Plan",
            body: "[x] Inspect the current UI\n[~] Simplify the transcript\n[ ] Verify the preview",
            status: .running,
            timestamp: .now,
            detail: nil
        )

        XCTAssertTrue(plan.kind.isCollapsibleActivity)
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: plan),
            "1/3 complete  ·  Simplify the transcript"
        )

        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: 48))
        cell.configure(with: plan, isExpanded: false)
        XCTAssertEqual(cell.layer?.borderWidth, 0)
        XCTAssertEqual(cell.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(cell.expansionControl.accessibilityValue() as? String, "Collapsed")

        var oversizedPlan = plan
        oversizedPlan.body = Array(repeating: "[x] Finished", count: 300).joined(separator: "\n")
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: oversizedPlan),
            "256/256 complete",
            "Collapsed plan summaries must inspect a bounded number of lines"
        )
    }

    @MainActor
    func testTranscriptBodyRendersMarkdownWithNativeTextAttributes() throws {
        let item = TimelineItem(
            id: "markdown-message",
            kind: .assistantMessage,
            title: nil,
            body: "# Result\n\n- **Built** the [preview](https://example.test)\n- Uses `native AppKit`",
            status: .completed,
            timestamp: .now,
            detail: nil
        )

        let rendered = TranscriptCellView.bodyAttributedText(for: item)
        XCTAssertEqual(
            rendered.string,
            "Result\n\n• Built the preview\n• Uses native AppKit"
        )

        let text = rendered.string as NSString
        let headingFont = try XCTUnwrap(
            rendered.attribute(.font, at: text.range(of: "Result").location, effectiveRange: nil) as? NSFont
        )
        XCTAssertGreaterThan(headingFont.pointSize, 14.5)

        let boldFont = try XCTUnwrap(
            rendered.attribute(.font, at: text.range(of: "Built").location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        let codeFont = try XCTUnwrap(
            rendered.attribute(.font, at: text.range(of: "native AppKit").location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(
            rendered.attribute(.link, at: text.range(of: "preview").location, effectiveRange: nil) as? URL,
            URL(string: "https://example.test")
        )
    }

    @MainActor
    func testCommandAndFileChangeBodiesRemainExactLiteralEvidence() {
        let body = "# not a heading\n---\n- removed\n+ added\n**literal markers**"
        for kind in [TimelineItemKind.command, .fileChange, .tool] {
            let item = TimelineItem(
                id: "literal-\(kind.rawValue)",
                kind: kind,
                title: nil,
                body: body,
                status: .completed,
                timestamp: .now,
                detail: nil
            )
            XCTAssertEqual(TranscriptCellView.bodyAttributedText(for: item).string, body)
        }
    }

    @MainActor
    func testMarkdownLinksAllowOnlyHTTPAndHTTPS() throws {
        let item = TimelineItem(
            id: "markdown-link-boundary",
            kind: .assistantMessage,
            title: nil,
            body: "[web](https://example.test) [file](file:///tmp/private) [settings](x-apple.systempreferences:privacy)",
            status: .completed,
            timestamp: .now,
            detail: nil
        )

        let rendered = TranscriptCellView.bodyAttributedText(for: item)
        let text = rendered.string as NSString
        XCTAssertEqual(
            rendered.attribute(.link, at: text.range(of: "web").location, effectiveRange: nil) as? URL,
            URL(string: "https://example.test")
        )
        XCTAssertNil(rendered.attribute(.link, at: text.range(of: "file").location, effectiveRange: nil))
        XCTAssertNil(rendered.attribute(.link, at: text.range(of: "settings").location, effectiveRange: nil))
    }

    @MainActor
    func testManyLineMarkdownUsesExactPlainTextFallback() {
        let body = Array(
            repeating: "- **literal**",
            count: TranscriptMarkdownRenderer.maximumMarkdownLines + 1
        ).joined(separator: "\n")
        let rendered = TranscriptMarkdownRenderer.attributedString(
            markdown: body,
            baseFont: .systemFont(ofSize: 14.5)
        )

        XCTAssertEqual(rendered.string, body)
    }

    @MainActor
    func testVeryLargeTranscriptBodyUsesExactPlainTextFallback() {
        let body = "**" + String(repeating: "x", count: TranscriptMarkdownRenderer.maximumMarkdownUTF8Bytes) + "**"
        let rendered = TranscriptMarkdownRenderer.attributedString(
            markdown: body,
            baseFont: .systemFont(ofSize: 14.5)
        )

        XCTAssertEqual(rendered.string, body)
        XCTAssertNil(
            rendered.attribute(
                NSAttributedString.Key("NSInlinePresentationIntent"),
                at: 0,
                effectiveRange: nil
            )
        )
    }

    @MainActor
    func testExpandedCardsRenderAllAttachmentsAndLinks() {
        let base = TimelineItem(
            id: "all-media",
            kind: .tool,
            title: "Inspect",
            body: "Output",
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        var item = base
        item.attachments = (0..<8).map { index in
            TimelineAttachment(
                id: "attachment-\(index)",
                source: .localFilePath("/tmp/attachment-\(index).png"),
                accessibilityLabel: "Attachment \(index)"
            )
        }
        item.links = (0..<8).map { index in
            TimelineResourceLink(
                id: "link-\(index)",
                title: "Reference \(index)",
                url: URL(string: "https://example.test/\(index)")!
            )
        }

        let boundedHeight = TranscriptCellView.height(for: item, width: 640)
        let expandedHeight = TranscriptCellView.height(for: item, width: 640, isExpanded: true)
        XCTAssertGreaterThan(expandedHeight, boundedHeight)

        let cell = TranscriptCellView(frame: NSRect(x: 0, y: 0, width: 640, height: expandedHeight))
        cell.configure(with: item, isExpanded: true)
        XCTAssertEqual(cell.subviews.filter { $0 is TranscriptAttachmentView }.count, 8)
        XCTAssertEqual(cell.subviews.filter { $0 is TranscriptResourceLinkView }.count, 8)
    }

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
        weak var weakView: TranscriptAttachmentView?
        weakView = view
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
