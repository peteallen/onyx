import Foundation

extension NSAttributedString.Key {
    /// Retains semantic meaning in the rendered transcript without making
    /// color the only machine-readable representation of that meaning.
    static let onyxSemanticRole = NSAttributedString.Key("OnyxSemanticRole")
}

/// The small, app-owned semantic vocabulary that models may request inside
/// assistant prose. Models choose a meaning; Onyx continues to own the color.
enum TranscriptSemanticRole: String, CaseIterable, Sendable {
    case intent
    case working
    case success
    case attention
    case failure
}

/// A UTF-16 range over `TranscriptSemanticMarkupProjection.cleanText`.
/// UTF-16 keeps the projection directly usable by AppKit attributed strings.
struct TranscriptSemanticRegion: Equatable, Sendable {
    let role: TranscriptSemanticRole
    let range: NSRange
}

/// Presentation-only interpretation of provider-authored assistant text.
///
/// `rawText` is retained verbatim so callers never need to replace durable
/// provider history with the marker-free projection. `cleanText` removes only
/// complete, known, nonnested wrappers; ordinary Markdown remains available
/// for the transcript renderer.
struct TranscriptSemanticMarkupProjection: Equatable, Sendable {
    let rawText: String
    let cleanText: String
    let regions: [TranscriptSemanticRegion]
}

enum TranscriptSemanticMarkup {
    static let maximumStyledRegions = 3
    static let maximumStyledRegionUTF8Bytes = 512
    static let maximumSourceUTF8Bytes = 128 * 1_024
    static let maximumSourceLines = 2_048

    private static let openingPrefix = "[onyx:"
    private static let closingTag = "[/onyx]"
    private static let maximumOpeningTagUTF16Length = 32

    private enum TokenKind {
        case opening(TranscriptSemanticRole?)
        case closing
    }

    private struct Token {
        let kind: TokenKind
        let range: NSRange
    }

    private enum ProtectedKind: Equatable {
        case inlineCode
        case fencedCode
        case indentedCode
        case linkDestination
        case html
    }

    private struct ProtectedRange {
        let range: NSRange
        let kind: ProtectedKind
    }

    private struct SourceLine {
        let lineStart: Int
        let lineEnd: Int
        let contentsEnd: Int
        let text: String
    }

    private struct Fence {
        let marker: unichar
        let runLength: Int
        let prefix: String
    }

    private struct Pair {
        let opening: Token
        let closing: Token
        let role: TranscriptSemanticRole
        let isBlock: Bool
    }

    static func project(_ source: String) -> TranscriptSemanticMarkupProjection {
        guard !source.isEmpty,
              source.utf8.count <= maximumSourceUTF8Bytes,
              hasBoundedLineCount(source) else {
            return literalProjection(source)
        }

        let sourceNSString = source as NSString
        let protectedRanges = markdownProtectedRanges(in: sourceNSString)
        let tokens = semanticTokens(
            in: sourceNSString,
            protectedRanges: protectedRanges
        )
        let pairs = validPairs(
            from: tokens,
            source: sourceNSString,
            protectedRanges: protectedRanges
        )
        guard !pairs.isEmpty else { return literalProjection(source) }

        let cleanText = NSMutableString()
        var regions: [TranscriptSemanticRegion] = []
        regions.reserveCapacity(min(maximumStyledRegions, pairs.count))
        var sourceCursor = 0

        var styledBlockCount = 0
        for pair in pairs {
            let prefixLength = pair.opening.range.location - sourceCursor
            if prefixLength > 0 {
                cleanText.append(
                    sourceNSString.substring(
                        with: NSRange(location: sourceCursor, length: prefixLength)
                    )
                )
            }

            let contentStart = NSMaxRange(pair.opening.range)
            let contentRange = NSRange(
                location: contentStart,
                length: pair.closing.range.location - contentStart
            )
            let content = sourceNSString.substring(with: contentRange)
            let cleanRange = NSRange(location: cleanText.length, length: content.utf16.count)
            cleanText.append(content)

            if regions.count < maximumStyledRegions,
               !content.isEmpty,
               content.utf8.count <= maximumStyledRegionUTF8Bytes,
               !pair.isBlock || styledBlockCount == 0 {
                regions.append(
                    TranscriptSemanticRegion(role: pair.role, range: cleanRange)
                )
                if pair.isBlock { styledBlockCount += 1 }
            }
            sourceCursor = NSMaxRange(pair.closing.range)
        }

        if sourceCursor < sourceNSString.length {
            cleanText.append(
                sourceNSString.substring(
                    with: NSRange(
                        location: sourceCursor,
                        length: sourceNSString.length - sourceCursor
                    )
                )
            )
        }

        return TranscriptSemanticMarkupProjection(
            rawText: source,
            cleanText: cleanText as String,
            regions: regions
        )
    }

    /// Marker-free text for copy, accessibility, previews, and other
    /// presentation surfaces. This intentionally removes only Onyx wrappers;
    /// callers may perform their usual Markdown-to-plain-text projection next.
    static func cleanText(from source: String) -> String {
        project(source).cleanText
    }

    private static func literalProjection(_ source: String) -> TranscriptSemanticMarkupProjection {
        TranscriptSemanticMarkupProjection(rawText: source, cleanText: source, regions: [])
    }

    private static func hasBoundedLineCount(_ source: String) -> Bool {
        // Count logical line breaks rather than newline scalars. In particular,
        // CRLF is one line separator, not two; treating it as two made otherwise
        // valid Windows-authored answers fall back to literal rendering early.
        var lineCount = 1
        var previousWasCarriageReturn = false
        for scalar in source.unicodeScalars {
            if scalar == "\r" {
                lineCount += 1
                previousWasCarriageReturn = true
            } else if scalar == "\n" {
                if !previousWasCarriageReturn { lineCount += 1 }
                previousWasCarriageReturn = false
            } else if CharacterSet.newlines.contains(scalar) {
                lineCount += 1
                previousWasCarriageReturn = false
            } else {
                previousWasCarriageReturn = false
            }
            if lineCount > maximumSourceLines { return false }
        }
        return true
    }

    /// Groups semantic tokens as balanced wrappers. A group is valid only
    /// when it contains exactly one known opening token and its closing token.
    /// This makes nested, unknown, and unclosed markup fail closed as literal
    /// text while allowing a later independent valid group to render normally.
    private static func validPairs(
        from tokens: [Token],
        source: NSString,
        protectedRanges: [ProtectedRange]
    ) -> [Pair] {
        var pairs: [Pair] = []
        var tokenIndex = 0

        while tokenIndex < tokens.count {
            let opening = tokens[tokenIndex]
            guard case let .opening(role) = opening.kind else {
                tokenIndex += 1
                continue
            }

            var depth = 1
            var nested = false
            var closingIndex = tokenIndex + 1
            while closingIndex < tokens.count {
                switch tokens[closingIndex].kind {
                case .opening:
                    depth += 1
                    nested = true
                case .closing:
                    depth -= 1
                }
                if depth == 0 { break }
                closingIndex += 1
            }

            guard closingIndex < tokens.count, depth == 0 else {
                // Every later token is inside this unclosed group, so none can
                // be interpreted safely as an independent wrapper.
                break
            }

            let contentStart = NSMaxRange(opening.range)
            let contentRange = NSRange(
                location: contentStart,
                length: tokens[closingIndex].range.location - contentStart
            )
            // Inline code and link destinations are ordinary inline content and
            // may safely occur inside a semantic wrapper. Block-code ranges are
            // evidence-like content: a wrapper crossing one is ambiguous and
            // therefore remains completely literal.
            let crossesBlockCode = protectedRanges.contains {
                guard $0.kind == .fencedCode || $0.kind == .indentedCode else {
                    return false
                }
                return NSIntersectionRange(contentRange, $0.range).length > 0
            }
            if !nested, !crossesBlockCode, let role {
                pairs.append(
                    Pair(
                        opening: opening,
                        closing: tokens[closingIndex],
                        role: role,
                        isBlock: isBlockPair(
                            opening: opening,
                            closing: tokens[closingIndex],
                            in: source
                        )
                    )
                )
            }
            tokenIndex = closingIndex + 1
        }
        return pairs
    }

    private static let openingUnits = Array(openingPrefix.utf16)
    private static let closingUnits = Array(closingTag.utf16)

    private static func semanticTokens(
        in source: NSString,
        protectedRanges: [ProtectedRange]
    ) -> [Token] {
        // Scan one UTF-16 unit at a time. The previous implementation searched
        // the complete remaining suffix for every marker, which became
        // quadratic for marker-heavy streamed answers.
        var tokens: [Token] = []
        var location = 0
        while location < source.length {
            if let protected = protectedRange(containing: location, in: protectedRanges) {
                location = max(NSMaxRange(protected.range), location + 1)
                continue
            }

            if source.character(at: location) == 0x5B, // [
               !isEscaped(location: location, in: source),
               matches(openingUnits, at: location, in: source) {
                let roleStart = location + openingUnits.count
                let searchEnd = min(
                    source.length,
                    location + maximumOpeningTagUTF16Length
                )
                var bracket = roleStart
                while bracket < searchEnd,
                      source.character(at: bracket) != 0x5D, // ]
                      !isNewline(source.character(at: bracket)) {
                    bracket += 1
                }
                guard bracket < searchEnd,
                      source.character(at: bracket) == 0x5D else {
                    location += openingUnits.count
                    continue
                }

                let roleText = source.substring(
                    with: NSRange(location: roleStart, length: bracket - roleStart)
                )
                // Unknown roles are tokenized as an opening boundary so they
                // invalidate an enclosing pair, but malformed role text is not
                // allowed to create an accidental boundary.
                guard isSyntacticRoleText(roleText) else {
                    location = bracket + 1
                    continue
                }
                let fullRange = NSRange(
                    location: location,
                    length: bracket + 1 - location
                )
                tokens.append(
                    Token(
                        kind: .opening(TranscriptSemanticRole(rawValue: roleText)),
                        range: fullRange
                    )
                )
                location = NSMaxRange(fullRange)
                continue
            }

            if source.character(at: location) == 0x5B,
               !isEscaped(location: location, in: source),
               matches(closingUnits, at: location, in: source) {
                tokens.append(
                    Token(
                        kind: .closing,
                        range: NSRange(location: location, length: closingUnits.count)
                    )
                )
                location += closingUnits.count
                continue
            }
            location += 1
        }
        return tokens
    }

    private static func isSyntacticRoleText(_ role: String) -> Bool {
        guard !role.isEmpty, role.utf8.count <= 24 else { return false }
        // Keep the grammar deliberately ASCII and identifier-like. This avoids
        // treating arbitrary prose such as `[onyx:success missing bracket]` as
        // a nesting boundary while still preserving it verbatim.
        return role.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) ||
            ($0 >= 0x61 && $0 <= 0x7A) ||
            ($0 >= 0x30 && $0 <= 0x39) ||
            $0 == 0x2D || $0 == 0x5F
        }
    }

    private static func matches(
        _ units: [UInt16],
        at location: Int,
        in source: NSString
    ) -> Bool {
        guard location >= 0, location + units.count <= source.length else {
            return false
        }
        for (offset, unit) in units.enumerated()
        where source.character(at: location + offset) != unit {
            return false
        }
        return true
    }

    private static func isEscaped(location: Int, in source: NSString) -> Bool {
        guard location > 0 else { return false }
        var backslashCount = 0
        var cursor = location - 1
        while cursor >= 0, source.character(at: cursor) == 0x5C {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func sourceLines(in source: NSString) -> [SourceLine] {
        var lines: [SourceLine] = []
        var location = 0
        while location < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let safeEnd = max(lineEnd, location + 1)
            lines.append(
                SourceLine(
                    lineStart: lineStart,
                    lineEnd: safeEnd,
                    contentsEnd: contentsEnd,
                    text: source.substring(
                        with: NSRange(location: lineStart, length: contentsEnd - lineStart)
                    )
                )
            )
            location = safeEnd
        }
        return lines
    }

    /// Protect Markdown evidence before looking for semantic wrappers. Fence
    /// matching is intentionally strict: the closing line must use the same
    /// marker character, exact run length, exact structural indentation (and
    /// blockquote prefix), with whitespace-only trailing content.
    private static func markdownProtectedRanges(in source: NSString) -> [ProtectedRange] {
        let lines = sourceLines(in: source)
        var ranges: [ProtectedRange] = []
        var activeFence: Fence?

        for line in lines {
            if let fence = activeFence {
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: line.lineStart, length: line.lineEnd - line.lineStart),
                        kind: .fencedCode
                    )
                )
                if isFenceClosing(line.text, matching: fence) {
                    activeFence = nil
                }
                continue
            }

            if let candidate = fenceCandidate(in: line.text) {
                activeFence = candidate
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: line.lineStart, length: line.lineEnd - line.lineStart),
                        kind: .fencedCode
                    )
                )
                continue
            }

            if isIndentedCodeLine(line.text) {
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: line.lineStart, length: line.lineEnd - line.lineStart),
                        kind: .indentedCode
                    )
                )
            }
        }

        ranges.sort { $0.range.location < $1.range.location }
        ranges.append(contentsOf: inlineCodeRanges(in: source, excluding: ranges))
        ranges.sort { $0.range.location < $1.range.location }
        ranges.append(contentsOf: linkDestinationRanges(in: source, excluding: ranges))
        ranges.sort { $0.range.location < $1.range.location }
        ranges.append(contentsOf: htmlRanges(in: source, excluding: ranges))
        return ranges.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length > $1.range.length
        }
    }

    private static func protectedRange(
        containing location: Int,
        in ranges: [ProtectedRange]
    ) -> ProtectedRange? {
        for candidate in ranges {
            if candidate.range.location > location { break }
            if location < NSMaxRange(candidate.range) { return candidate }
        }
        return nil
    }

    private static func fenceCandidate(in line: String) -> Fence? {
        let value = line as NSString
        var cursor = 0
        var prefix = ""
        var sawBlockquote = false

        while cursor < value.length {
            let indentationStart = cursor
            while cursor < value.length,
                  value.character(at: cursor) == 0x20 || value.character(at: cursor) == 0x09 {
                cursor += 1
            }
            if cursor < value.length, value.character(at: cursor) == 0x3E { // >
                prefix += value.substring(
                    with: NSRange(location: indentationStart, length: cursor - indentationStart + 1)
                )
                cursor += 1
                if cursor < value.length, value.character(at: cursor) == 0x20 {
                    prefix += " "
                    cursor += 1
                }
                sawBlockquote = true
                continue
            }

            prefix += value.substring(
                with: NSRange(location: indentationStart, length: cursor - indentationStart)
            )
            break
        }

        // Four-space indentation is an indented code block, not a fence.
        if !sawBlockquote,
           prefix.utf8.filter({ $0 == 0x20 || $0 == 0x09 }).count > 3 {
            return nil
        }
        guard cursor < value.length else { return nil }
        let marker = value.character(at: cursor)
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var runEnd = cursor
        while runEnd < value.length, value.character(at: runEnd) == marker {
            runEnd += 1
        }
        guard runEnd - cursor >= 3 else { return nil }
        return Fence(marker: marker, runLength: runEnd - cursor, prefix: prefix)
    }

    private static func isFenceClosing(_ line: String, matching fence: Fence) -> Bool {
        guard let candidate = fenceCandidate(in: line),
              candidate.marker == fence.marker,
              candidate.runLength == fence.runLength,
              candidate.prefix == fence.prefix else {
            return false
        }
        let value = line as NSString
        let markerStart = fence.prefix.utf16.count
        var cursor = markerStart + fence.runLength
        while cursor < value.length {
            let unit = value.character(at: cursor)
            guard unit == 0x20 || unit == 0x09 else { return false }
            cursor += 1
        }
        return true
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        let value = line as NSString
        var cursor = 0
        while cursor < value.length {
            let indentStart = cursor
            while cursor < value.length,
                  value.character(at: cursor) == 0x20 || value.character(at: cursor) == 0x09 {
                cursor += 1
            }
            let indentLength = cursor - indentStart
            if cursor < value.length, value.character(at: cursor) == 0x3E { // >
                cursor += 1
                if cursor < value.length, value.character(at: cursor) == 0x20 { cursor += 1 }
                continue
            }
            return indentLength >= 4 || (indentLength > 0 && value.character(at: indentStart) == 0x09)
        }
        return false
    }

    private static func inlineCodeRanges(
        in source: NSString,
        excluding blockRanges: [ProtectedRange]
    ) -> [ProtectedRange] {
        var ranges: [ProtectedRange] = []
        var cursor = 0
        while cursor < source.length {
            if let protected = protectedRange(containing: cursor, in: blockRanges),
               protected.kind == .fencedCode || protected.kind == .indentedCode {
                cursor = max(NSMaxRange(protected.range), cursor + 1)
                continue
            }
            guard source.character(at: cursor) == 0x60,
                  !isEscaped(location: cursor, in: source) else {
                cursor += 1
                continue
            }

            let openingStart = cursor
            while cursor < source.length, source.character(at: cursor) == 0x60 {
                cursor += 1
            }
            let runLength = cursor - openingStart
            var candidate = cursor
            var closing: NSRange?
            while candidate < source.length {
                if let protected = protectedRange(containing: candidate, in: blockRanges),
                   protected.kind == .fencedCode || protected.kind == .indentedCode {
                    candidate = max(NSMaxRange(protected.range), candidate + 1)
                    continue
                }
                guard source.character(at: candidate) == 0x60 else {
                    candidate += 1
                    continue
                }
                var runEnd = candidate
                while runEnd < source.length, source.character(at: runEnd) == 0x60 {
                    runEnd += 1
                }
                if runEnd - candidate == runLength {
                    closing = NSRange(
                        location: openingStart,
                        length: runEnd - openingStart
                    )
                    cursor = runEnd
                    break
                }
                candidate = runEnd
            }

            if let closing {
                ranges.append(ProtectedRange(range: closing, kind: .inlineCode))
            } else {
                // An incomplete streaming span protects the complete remaining
                // answer, including later lines, until a matching close arrives.
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: openingStart, length: source.length - openingStart),
                        kind: .inlineCode
                    )
                )
                break
            }
        }
        return ranges
    }

    private static func linkDestinationRanges(
        in source: NSString,
        excluding protectedRanges: [ProtectedRange]
    ) -> [ProtectedRange] {
        var ranges: [ProtectedRange] = []
        var location = 0
        while location < source.length {
            if let protected = protectedRange(containing: location, in: protectedRanges) {
                location = max(NSMaxRange(protected.range), location + 1)
                continue
            }
            guard source.character(at: location) == 0x5D, // ]
                  !isEscaped(location: location, in: source),
                  location + 1 < source.length,
                  source.character(at: location + 1) == 0x28 else { // (
                location += 1
                continue
            }
            let destinationStart = location + 2
            var cursor = destinationStart
            var depth = 1
            while cursor < source.length {
                if let protected = protectedRange(containing: cursor, in: protectedRanges) {
                    cursor = max(NSMaxRange(protected.range), cursor + 1)
                    continue
                }
                let unit = source.character(at: cursor)
                if unit == 0x5C {
                    cursor += min(2, source.length - cursor)
                    continue
                }
                if unit == 0x28 { depth += 1 }
                if unit == 0x29 {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor += 1
            }
            let destinationEnd = min(cursor, source.length)
            if destinationEnd > destinationStart {
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: destinationStart, length: destinationEnd - destinationStart),
                        kind: .linkDestination
                    )
                )
            }
            location = max(cursor + 1, location + 1)
        }
        return ranges
    }

    private static func htmlRanges(
        in source: NSString,
        excluding protectedRanges: [ProtectedRange]
    ) -> [ProtectedRange] {
        var ranges: [ProtectedRange] = []
        var location = 0
        while location < source.length {
            if let protected = protectedRange(containing: location, in: protectedRanges) {
                location = max(NSMaxRange(protected.range), location + 1)
                continue
            }
            guard source.character(at: location) == 0x3C, // <
                  !isEscaped(location: location, in: source) else {
                location += 1
                continue
            }
            let remaining = NSRange(location: location, length: source.length - location)
            if source.range(of: "<!--", options: [], range: remaining).location == location {
                let endRange = source.range(of: "-->", options: [], range: NSRange(
                    location: location + 4,
                    length: source.length - location - 4
                ))
                let end = endRange.location == NSNotFound ? source.length : NSMaxRange(endRange)
                ranges.append(
                    ProtectedRange(
                        range: NSRange(location: location, length: end - location),
                        kind: .html
                    )
                )
                location = end
                continue
            }

            var cursor = location + 1
            var quote: unichar = 0
            while cursor < source.length {
                let unit = source.character(at: cursor)
                if quote != 0 {
                    if unit == quote { quote = 0 }
                } else if unit == 0x22 || unit == 0x27 {
                    quote = unit
                } else if unit == 0x3E {
                    cursor += 1
                    break
                }
                cursor += 1
            }
            guard cursor > location + 1, cursor <= source.length else {
                location += 1
                continue
            }
            let tagRange = NSRange(location: location, length: cursor - location)
            ranges.append(ProtectedRange(range: tagRange, kind: .html))

            let tagText = source.substring(with: tagRange).lowercased()
            if tagText.hasPrefix("<code") || tagText.hasPrefix("<pre") {
                let name = tagText.hasPrefix("<code") ? "</code" : "</pre"
                let closeRange = source.range(
                    of: name,
                    options: .caseInsensitive,
                    range: NSRange(location: cursor, length: source.length - cursor)
                )
                if closeRange.location != NSNotFound {
                    var closeEnd = NSMaxRange(closeRange)
                    while closeEnd < source.length, source.character(at: closeEnd) != 0x3E {
                        closeEnd += 1
                    }
                    if closeEnd < source.length { closeEnd += 1 }
                    ranges.append(
                        ProtectedRange(
                            range: NSRange(location: cursor, length: closeEnd - cursor),
                            kind: .html
                        )
                    )
                    location = closeEnd
                    continue
                }
            }
            location = cursor
        }
        return ranges
    }

    private static func isBlockPair(
        opening: Token,
        closing: Token,
        in source: NSString
    ) -> Bool {
        let openingLine = lineBounds(containing: opening.range.location, in: source)
        let closingLine = lineBounds(containing: closing.range.location, in: source)
        guard openingLine.lineStart != closingLine.lineStart else { return false }
        let beforeOpening = source.substring(
            with: NSRange(
                location: openingLine.lineStart,
                length: opening.range.location - openingLine.lineStart
            )
        )
        let afterOpening = source.substring(
            with: NSRange(
                location: NSMaxRange(opening.range),
                length: openingLine.contentsEnd - NSMaxRange(opening.range)
            )
        )
        let beforeClosing = source.substring(
            with: NSRange(
                location: closingLine.lineStart,
                length: closing.range.location - closingLine.lineStart
            )
        )
        let afterClosing = source.substring(
            with: NSRange(
                location: NSMaxRange(closing.range),
                length: closingLine.contentsEnd - NSMaxRange(closing.range)
            )
        )
        return isHorizontalWhitespace(beforeOpening) &&
            isHorizontalWhitespace(afterOpening) &&
            isHorizontalWhitespace(beforeClosing) &&
            isHorizontalWhitespace(afterClosing)
    }

    private static func lineBounds(containing location: Int, in source: NSString) -> SourceLine {
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: min(location, source.length), length: 0)
        )
        return SourceLine(
            lineStart: lineStart,
            lineEnd: max(lineEnd, lineStart),
            contentsEnd: contentsEnd,
            text: source.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        )
    }

    private static func isHorizontalWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
