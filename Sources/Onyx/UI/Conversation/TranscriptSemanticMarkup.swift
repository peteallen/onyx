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

    private struct Pair {
        let opening: Token
        let closing: Token
        let role: TranscriptSemanticRole
    }

    static func project(_ source: String) -> TranscriptSemanticMarkupProjection {
        guard !source.isEmpty,
              source.utf8.count <= maximumSourceUTF8Bytes,
              hasBoundedLineCount(source) else {
            return literalProjection(source)
        }

        let sourceNSString = source as NSString
        let protectedRanges = markdownCodeRanges(in: sourceNSString)
        let tokens = semanticTokens(
            in: sourceNSString,
            protectedRanges: protectedRanges
        )
        let pairs = validPairs(from: tokens, protectedRanges: protectedRanges)
        guard !pairs.isEmpty else { return literalProjection(source) }

        let cleanText = NSMutableString()
        var regions: [TranscriptSemanticRegion] = []
        regions.reserveCapacity(min(maximumStyledRegions, pairs.count))
        var sourceCursor = 0

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
               content.utf8.count <= maximumStyledRegionUTF8Bytes {
                regions.append(
                    TranscriptSemanticRegion(role: pair.role, range: cleanRange)
                )
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
        var lineBreakCount = 0
        for scalar in source.unicodeScalars where CharacterSet.newlines.contains(scalar) {
            lineBreakCount += 1
            if lineBreakCount >= maximumSourceLines { return false }
        }
        return true
    }

    /// Groups semantic tokens as balanced wrappers. A group is valid only
    /// when it contains exactly one known opening token and its closing token.
    /// This makes nested, unknown, and unclosed markup fail closed as literal
    /// text while allowing a later independent valid group to render normally.
    private static func validPairs(
        from tokens: [Token],
        protectedRanges: [NSRange]
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
            let crossesProtectedContent = protectedRanges.contains {
                NSIntersectionRange(contentRange, $0).length > 0
            }
            if !nested, !crossesProtectedContent, let role {
                pairs.append(
                    Pair(
                        opening: opening,
                        closing: tokens[closingIndex],
                        role: role
                    )
                )
            }
            tokenIndex = closingIndex + 1
        }
        return pairs
    }

    private static func semanticTokens(
        in source: NSString,
        protectedRanges: [NSRange]
    ) -> [Token] {
        var tokens: [Token] = []
        var searchLocation = 0
        var protectedIndex = 0

        while searchLocation < source.length {
            while protectedIndex < protectedRanges.count,
                  NSMaxRange(protectedRanges[protectedIndex]) <= searchLocation {
                protectedIndex += 1
            }

            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            let openingRange = source.range(of: openingPrefix, options: [], range: searchRange)
            let closingRange = source.range(of: closingTag, options: [], range: searchRange)
            let candidateRange: NSRange
            let isOpening: Bool

            if openingRange.location == NSNotFound {
                guard closingRange.location != NSNotFound else { break }
                candidateRange = closingRange
                isOpening = false
            } else if closingRange.location == NSNotFound || openingRange.location < closingRange.location {
                candidateRange = openingRange
                isOpening = true
            } else {
                candidateRange = closingRange
                isOpening = false
            }

            // A candidate may jump past one or more protected ranges without
            // encountering a marker inside them. Advance against the
            // candidate itself before testing containment.
            while protectedIndex < protectedRanges.count,
                  NSMaxRange(protectedRanges[protectedIndex]) <= candidateRange.location {
                protectedIndex += 1
            }
            if protectedIndex < protectedRanges.count,
               NSLocationInRange(candidateRange.location, protectedRanges[protectedIndex]) {
                searchLocation = NSMaxRange(protectedRanges[protectedIndex])
                continue
            }
            if isEscaped(location: candidateRange.location, in: source) {
                searchLocation = NSMaxRange(candidateRange)
                continue
            }

            if isOpening {
                let remainingLength = min(
                    maximumOpeningTagUTF16Length,
                    source.length - candidateRange.location
                )
                let openingSearchRange = NSRange(
                    location: candidateRange.location,
                    length: remainingLength
                )
                let bracketRange = source.range(of: "]", options: [], range: openingSearchRange)
                guard bracketRange.location != NSNotFound else {
                    searchLocation = NSMaxRange(candidateRange)
                    continue
                }
                let fullRange = NSRange(
                    location: candidateRange.location,
                    length: NSMaxRange(bracketRange) - candidateRange.location
                )
                let roleStart = NSMaxRange(candidateRange)
                let roleText = source.substring(
                    with: NSRange(
                        location: roleStart,
                        length: bracketRange.location - roleStart
                    )
                )
                tokens.append(
                    Token(
                        kind: .opening(TranscriptSemanticRole(rawValue: roleText)),
                        range: fullRange
                    )
                )
                searchLocation = NSMaxRange(fullRange)
            } else {
                tokens.append(Token(kind: .closing, range: candidateRange))
                searchLocation = NSMaxRange(candidateRange)
            }
        }
        return tokens
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

    /// Mirrors the transcript's intentionally small Markdown surface: fenced
    /// blocks begin with a trimmed triple backtick/tilde line, and inline code
    /// is protected from one matching backtick run through the next.
    private static func markdownCodeRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        var fence: String?

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
            let contentRange = NSRange(
                location: lineStart,
                length: contentsEnd - lineStart
            )
            let line = source.substring(with: contentRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let currentFence = fence {
                ranges.append(NSRange(location: lineStart, length: lineEnd - lineStart))
                if trimmed.hasPrefix(currentFence) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                ranges.append(NSRange(location: lineStart, length: lineEnd - lineStart))
            } else {
                ranges.append(contentsOf: inlineCodeRanges(in: source, range: contentRange))
            }
            location = max(lineEnd, location + 1)
        }
        return ranges
    }

    private static func inlineCodeRanges(in source: NSString, range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = range.location
        let rangeEnd = NSMaxRange(range)

        while cursor < rangeEnd {
            guard source.character(at: cursor) == 0x60,
                  !isEscaped(location: cursor, in: source) else {
                cursor += 1
                continue
            }

            let openingStart = cursor
            while cursor < rangeEnd, source.character(at: cursor) == 0x60 {
                cursor += 1
            }
            let runLength = cursor - openingStart
            var closingStart = cursor
            var foundClosing = false

            while closingStart < rangeEnd {
                if source.character(at: closingStart) == 0x60,
                   !isEscaped(location: closingStart, in: source) {
                    var closingEnd = closingStart
                    while closingEnd < rangeEnd,
                          source.character(at: closingEnd) == 0x60 {
                        closingEnd += 1
                    }
                    if closingEnd - closingStart == runLength {
                        ranges.append(
                            NSRange(
                                location: openingStart,
                                length: closingEnd - openingStart
                            )
                        )
                        cursor = closingEnd
                        foundClosing = true
                        break
                    }
                    closingStart = closingEnd
                } else {
                    closingStart += 1
                }
            }

            if !foundClosing {
                // An unfinished code span is ambiguous while streaming. Keep
                // the rest of the line literal rather than styling through it.
                ranges.append(
                    NSRange(location: openingStart, length: rangeEnd - openingStart)
                )
                break
            }
        }
        return ranges
    }
}
