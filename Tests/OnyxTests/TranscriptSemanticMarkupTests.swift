import AppKit
import XCTest
@testable import Onyx

@MainActor
final class TranscriptSemanticMarkupTests: XCTestCase {
    func testProjectionKeepsRawTextAndExposesCleanRoleRanges() {
        let source = "Plan [onyx:intent]the approach[/onyx], then [onyx:success]ship it[/onyx]."
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.rawText, source)
        XCTAssertEqual(projection.cleanText, "Plan the approach, then ship it.")
        XCTAssertEqual(projection.regions.map(\.role), [.intent, .success])
        XCTAssertEqual(projectedStrings(projection), ["the approach", "ship it"])
        XCTAssertEqual(TranscriptSemanticMarkup.cleanText(from: source), projection.cleanText)
    }

    func testUnknownMalformedNestedUnclosedAndEscapedMarkupRemainLiteral() {
        let literalSources = [
            "[onyx:celebrate]No invented roles[/onyx]",
            "[onyx:success missing bracket[/onyx]",
            "[onyx:success]outer [onyx:failure]inner[/onyx][/onyx]",
            "[onyx:working]still streaming",
            #"\[onyx:success]escaped[/onyx]"#,
            "orphan [/onyx] marker",
        ]

        for source in literalSources {
            let projection = TranscriptSemanticMarkup.project(source)
            XCTAssertEqual(projection.cleanText, source)
            XCTAssertTrue(projection.regions.isEmpty)
        }
    }

    func testInlineAndFencedCodeNeverProduceSemanticRegions() {
        let source = """
        `[onyx:success]inline[/onyx]`
        ```text
        [onyx:failure]fenced[/onyx]
        ```
        [onyx:working]outside[/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertTrue(projection.cleanText.contains("[onyx:success]inline[/onyx]"))
        XCTAssertTrue(projection.cleanText.contains("[onyx:failure]fenced[/onyx]"))
        XCTAssertFalse(projection.cleanText.contains("[onyx:working]"))
        XCTAssertEqual(projection.regions.map(\.role), [.working])
        XCTAssertEqual(projectedStrings(projection), ["outside"])
    }

    func testARegionCannotWrapAcrossProtectedCode() {
        let source = """
        [onyx:success]
        ```text
        [onyx:failure]literal[/onyx]
        ```
        [/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.cleanText, source)
        XCTAssertTrue(projection.regions.isEmpty)
    }

    func testFencesRequireExactDelimiterIndentationAndWhitespaceOnlyClose() {
        let sources = [
            """
            ```
            ```not-a-close
            [onyx:success]inside[/onyx]
            ```
            """,
            """
            ````
            ```
            [onyx:success]inside[/onyx]
            ````
            """,
            """
            > ```
            ```
            > [onyx:success]inside[/onyx]
            > ```
            """,
        ]

        for source in sources {
            let projection = TranscriptSemanticMarkup.project(source)
            XCTAssertEqual(projection.cleanText, source)
            XCTAssertTrue(projection.regions.isEmpty)
        }
    }

    func testMultilineInlineCodeNeverInterpretsContainedMarkers() {
        let source = """
        `code
        [onyx:failure]literal[/onyx]
        more`
        [onyx:working]outside[/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertTrue(projection.cleanText.contains("[onyx:failure]literal[/onyx]"))
        XCTAssertFalse(projection.cleanText.contains("[onyx:working]"))
        XCTAssertEqual(projectedStrings(projection), ["outside"])
    }

    func testIndentedAndBlockquoteCodeProtectMarkers() {
        let source = """
            [onyx:failure]indented[/onyx]
        >     [onyx:attention]quoted code[/onyx]
        [onyx:success]outside[/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertTrue(projection.cleanText.contains("[onyx:failure]indented[/onyx]"))
        XCTAssertTrue(projection.cleanText.contains("[onyx:attention]quoted code[/onyx]"))
        XCTAssertEqual(projectedStrings(projection), ["outside"])
    }

    func testSemanticWrapperMayContainOrdinaryInlineCode() {
        let source = "[onyx:success]Built `thing` safely[/onyx]"
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.cleanText, "Built `thing` safely")
        XCTAssertEqual(projectedStrings(projection), ["Built `thing` safely"])
    }

    func testMarkersInsideInlineCodeLinkDestinationsAndHTMLRemainLiteral() {
        let source = """
        `[onyx:success]code[/onyx]`
        [link](https://example.test/[onyx:failure]literal[/onyx])
        <code>[onyx:attention]literal[/onyx]</code>
        [onyx:working]outside[/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertTrue(projection.cleanText.contains("[onyx:success]code[/onyx]"))
        XCTAssertTrue(projection.cleanText.contains("[onyx:failure]literal[/onyx]"))
        XCTAssertTrue(projection.cleanText.contains("[onyx:attention]literal[/onyx]"))
        XCTAssertEqual(projectedStrings(projection), ["outside"])
    }

    func testUnicodeBeforeMarkersKeepsUTF16RangesExact() {
        let source = "👩🏽‍💻 café [onyx:success]✅ résumé 🚀[/onyx] end"
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.rawText, source)
        XCTAssertEqual(projection.cleanText, "👩🏽‍💻 café ✅ résumé 🚀 end")
        XCTAssertEqual(projectedStrings(projection), ["✅ résumé 🚀"])
    }

    func testOnlyOneBlockAndThreeTotalRegionsAreStyled() {
        let source = """
        [onyx:success]
        first block
        [/onyx]
        [onyx:attention]
        second block
        [/onyx]
        [onyx:working]inline one[/onyx]
        [onyx:intent]inline two[/onyx]
        """
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertFalse(projection.cleanText.contains("[onyx:"))
        XCTAssertEqual(
            projectedStrings(projection),
            ["\nfirst block\n", "inline one", "inline two"]
        )
    }

    func testMarkerHeavySourceStaysBoundedAndLiteral() {
        let source = String(repeating: "[onyx:success]", count: 8_000)
        let start = CFAbsoluteTimeGetCurrent()
        let projection = TranscriptSemanticMarkup.project(source)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(projection.cleanText, source)
        XCTAssertTrue(projection.regions.isEmpty)
        XCTAssertLessThan(elapsed, 0.5, "Marker-heavy input must remain linear-time")
    }

    func testCRLFLineBoundCountsLogicalLinesOnce() {
        let lineCount = TranscriptSemanticMarkup.maximumSourceLines
        let source = Array(repeating: "line", count: lineCount - 1)
            .joined(separator: "\r\n") + "\r\n[onyx:success]last[/onyx]"
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertFalse(projection.cleanText.contains("[onyx:success]"))
        XCTAssertEqual(projectedStrings(projection), ["last"])
    }

    func testProjectionStylesOnlyThreeShortRegionsAndCleansEveryValidWrapper() {
        let source = (0..<4)
            .map { "[onyx:success]region-\($0)[/onyx]" }
            .joined(separator: " ")
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.cleanText, "region-0 region-1 region-2 region-3")
        XCTAssertEqual(projection.regions.count, TranscriptSemanticMarkup.maximumStyledRegions)
        XCTAssertEqual(projectedStrings(projection), ["region-0", "region-1", "region-2"])

        let oversized = String(
            repeating: "x",
            count: TranscriptSemanticMarkup.maximumStyledRegionUTF8Bytes + 1
        )
        let oversizedProjection = TranscriptSemanticMarkup.project(
            "[onyx:attention]\(oversized)[/onyx]"
        )
        XCTAssertEqual(oversizedProjection.cleanText, oversized)
        XCTAssertTrue(oversizedProjection.regions.isEmpty)
    }

    func testAssistantSemanticRolesRenderAsForegroundOnlyInBothAppearances() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let roles: [(TranscriptSemanticRole, (NSAppearance?) -> NSColor)] = [
            (.intent, OnyxTheme.irisNSColor),
            (.working, OnyxTheme.electricNSColor),
            (.success, OnyxTheme.successNSColor),
            (.attention, OnyxTheme.warningNSColor),
            (.failure, OnyxTheme.destructiveNSColor),
        ]

        for appearance in [dark, light] {
            for (role, expectedColor) in roles {
                let source = "Before [onyx:\(role.rawValue)]semantic words[/onyx] after"
                let item = assistantItem(body: source)
                let rendered = TranscriptCellView.bodyAttributedText(
                    for: item,
                    appearance: appearance
                )
                let range = (rendered.string as NSString).range(of: "semantic words")

                XCTAssertEqual(rendered.string, "Before semantic words after")
                XCTAssertEqual(
                    rendered.attribute(.onyxSemanticRole, at: range.location, effectiveRange: nil) as? String,
                    role.rawValue
                )
                XCTAssertEqual(
                    rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
                    expectedColor(appearance)
                )
                XCTAssertNil(
                    rendered.attribute(.backgroundColor, at: range.location, effectiveRange: nil),
                    "Semantic emphasis must not add geometry or a background wash"
                )
                XCTAssertEqual(item.body, source, "Presentation must not replace durable provider text")
            }
        }
    }

    func testSemanticRegionPreservesMarkdownInsideTheWrapper() throws {
        let item = assistantItem(
            body: "[onyx:success]**Built** the [preview](https://example.test)[/onyx]"
        )
        let rendered = TranscriptCellView.bodyAttributedText(for: item)
        let text = rendered.string as NSString
        let builtRange = text.range(of: "Built")
        let previewRange = text.range(of: "preview")

        XCTAssertEqual(rendered.string, "Built the preview")
        XCTAssertEqual(
            rendered.attribute(.onyxSemanticRole, at: builtRange.location, effectiveRange: nil) as? String,
            TranscriptSemanticRole.success.rawValue
        )
        let builtFont = try XCTUnwrap(
            rendered.attribute(.font, at: builtRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: builtFont).contains(.boldFontMask))
        XCTAssertEqual(
            rendered.attribute(.link, at: previewRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.test")
        )
    }

    func testSemanticRegionInsideOuterMarkdownEmphasisKeepsTheEmphasis() throws {
        let item = assistantItem(body: "**[onyx:success]Built[/onyx] today**")
        let rendered = TranscriptCellView.bodyAttributedText(for: item)
        XCTAssertEqual(rendered.string, "Built today")
        let builtRange = (rendered.string as NSString).range(of: "Built")
        let builtFont = try XCTUnwrap(
            rendered.attribute(.font, at: builtRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(
            NSFontManager.shared.traits(of: builtFont).contains(.boldFontMask),
            "Outer Markdown emphasis should survive semantic marker removal"
        )
    }

    func testUnicodeAndMarkdownBlockPrefixesKeepSemanticRangeAligned() throws {
        let source = "# 😀 [onyx:success]café 🚀[/onyx]"
        let item = assistantItem(body: source)
        let rendered = TranscriptCellView.bodyAttributedText(for: item)
        let text = rendered.string as NSString
        let semanticRange = text.range(of: "café 🚀")

        XCTAssertEqual(rendered.string, "😀 café 🚀")
        XCTAssertEqual(semanticRange.location, 3, "UTF-16 range should follow the heading's rendered text")
        XCTAssertEqual(
            rendered.attribute(.onyxSemanticRole, at: semanticRange.location, effectiveRange: nil) as? String,
            TranscriptSemanticRole.success.rawValue
        )
        let color = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: semanticRange.location, effectiveRange: nil) as? NSColor
        )
        XCTAssertEqual(color, OnyxTheme.successNSColor(for: nil))
    }

    func testLineBoundFallbackLeavesMarkersLiteral() {
        let source = (0...TranscriptSemanticMarkup.maximumSourceLines)
            .map { index in
                index == 0 ? "[onyx:success]first[/onyx]" : "line \(index)"
            }
            .joined(separator: "\n")
        let projection = TranscriptSemanticMarkup.project(source)

        XCTAssertEqual(projection.cleanText, source)
        XCTAssertTrue(projection.regions.isEmpty)
    }

    func testOnlyAssistantMessagesInterpretSemanticMarkup() {
        let source = "[onyx:success]Do not style user text[/onyx]"
        let userItem = TimelineItem(
            id: "semantic-user",
            kind: .userMessage,
            title: nil,
            body: source,
            status: .completed,
            timestamp: .now,
            detail: nil
        )
        let rendered = TranscriptCellView.bodyAttributedText(for: userItem)

        XCTAssertEqual(rendered.string, source)
        XCTAssertNil(
            rendered.attribute(.onyxSemanticRole, at: 0, effectiveRange: nil)
        )
        XCTAssertEqual(userItem.body, source)
    }

    func testIncompleteStreamingMarkupStaysLiteralUntilTheCloseArrives() {
        let partialSource = "Status: [onyx:working]Checking tests"
        let partial = TranscriptCellView.bodyAttributedText(
            for: assistantItem(body: partialSource)
        )
        XCTAssertEqual(partial.string, partialSource)
        XCTAssertNil(partial.attribute(.onyxSemanticRole, at: 0, effectiveRange: nil))

        let completeSource = partialSource + "[/onyx]"
        let completeItem = assistantItem(body: completeSource)
        let complete = TranscriptCellView.bodyAttributedText(for: completeItem)
        let checking = (complete.string as NSString).range(of: "Checking tests")
        XCTAssertEqual(complete.string, "Status: Checking tests")
        XCTAssertEqual(
            complete.attribute(.onyxSemanticRole, at: checking.location, effectiveRange: nil) as? String,
            TranscriptSemanticRole.working.rawValue
        )
        XCTAssertEqual(completeItem.body, completeSource)
    }

    func testCompactAssistantPreviewUsesTheCleanProjection() {
        let item = assistantItem(
            body: "[onyx:attention]Needs your choice[/onyx] before continuing"
        )
        XCTAssertEqual(
            TranscriptCellView.compactSummary(for: item),
            "Needs your choice before continuing"
        )
    }

    private func projectedStrings(
        _ projection: TranscriptSemanticMarkupProjection
    ) -> [String] {
        let cleanText = projection.cleanText as NSString
        return projection.regions.map { cleanText.substring(with: $0.range) }
    }

    private func assistantItem(body: String) -> TimelineItem {
        TimelineItem(
            id: "semantic-assistant",
            kind: .assistantMessage,
            title: nil,
            body: body,
            status: .completed,
            timestamp: .now,
            detail: nil
        )
    }
}
