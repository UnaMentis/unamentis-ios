// UnaMentis - MarkdownStripper
// Converts markdown text to clean plaintext suitable for TTS playback.
// Removes all markdown syntax while preserving the readable content.
//
// Part of Core/ReadingList

import Foundation

// MARK: - Markdown Stripper

/// Strips markdown syntax from text to produce clean, TTS-ready output.
///
/// Used during reading list import to ensure markdown formatting characters
/// are not read aloud (e.g., "## Introduction" becomes "Introduction").
public struct MarkdownStripper: Sendable {

    public init() { }

    /// Strip all markdown syntax from the input text
    /// - Parameter text: Raw markdown text
    /// - Returns: Clean plaintext suitable for TTS
    public func stripMarkdown(_ text: String) -> String {
        var result = text

        // 1. Remove YAML front matter
        result = removeFrontMatter(result)

        // 2. Remove HTML comments
        result = removeHTMLComments(result)

        // 3. Remove fenced code blocks (preserve inner text)
        result = removeFencedCodeBlocks(result)

        // 4. Remove images (drop entirely or keep alt text)
        result = removeImages(result)

        // 5. Convert links to just their display text
        result = removeLinks(result)

        // 6. Remove reference-style link definitions
        result = removeReferenceLinkDefinitions(result)

        // 7. Remove bold/italic/strikethrough formatting
        result = removeEmphasis(result)

        // 8. Remove inline code backticks
        result = removeInlineCode(result)

        // 9. Convert headers to plain text with paragraph break
        result = removeHeaders(result)

        // 10. Remove blockquote markers
        result = removeBlockquotes(result)

        // 11. Remove horizontal rules
        result = removeHorizontalRules(result)

        // 12. Remove list markers
        result = removeListMarkers(result)

        // 13. Remove footnote references
        result = removeFootnoteReferences(result)

        // 14. Remove footnote definitions
        result = removeFootnoteDefinitions(result)

        // 15. Strip any remaining inline HTML tags
        result = removeInlineHTML(result)

        // 16. Decode common HTML entities
        result = decodeHTMLEntities(result)

        // 17. Normalize whitespace
        result = normalizeWhitespace(result)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Methods

    private func removeFrontMatter(_ text: String) -> String {
        // Match YAML front matter at the start of the document
        let pattern = #"^---\n[\s\S]*?\n---\n?"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeHTMLComments(_ text: String) -> String {
        let pattern = #"<!--[\s\S]*?-->"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeFencedCodeBlocks(_ text: String) -> String {
        // Remove fenced code blocks, keeping the inner text
        let pattern = #"```[^\n]*\n([\s\S]*?)```"#
        return replace(in: text, pattern: pattern, with: "$1")
    }

    private func removeImages(_ text: String) -> String {
        // ![alt text](url) or ![alt text](url "title")
        // Keep alt text if present, otherwise remove entirely
        let pattern = #"!\[([^\]]*)\]\([^)]*\)"#
        return replaceWithClosure(in: text, pattern: pattern) { match in
            let altText = match.group(1)
            if let alt = altText, !alt.isEmpty {
                return alt + "."
            }
            return ""
        }
    }

    private func removeLinks(_ text: String) -> String {
        // [display text](url) -> display text
        var result = text
        let inlinePattern = #"\[([^\]]+)\]\([^)]*\)"#
        result = replace(in: result, pattern: inlinePattern, with: "$1")

        // [display text][ref] -> display text
        let refPattern = #"\[([^\]]+)\]\[[^\]]*\]"#
        result = replace(in: result, pattern: refPattern, with: "$1")

        return result
    }

    private func removeReferenceLinkDefinitions(_ text: String) -> String {
        // [ref]: url "title" (at start of line)
        let pattern = #"(?m)^\[[^\]]+\]:\s+\S+.*$"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeEmphasis(_ text: String) -> String {
        var result = text

        // Bold + italic combined: ***text*** or ___text___
        result = replace(in: result, pattern: #"\*\*\*(.+?)\*\*\*"#, with: "$1")
        result = replace(in: result, pattern: #"___(.+?)___"#, with: "$1")

        // Bold: **text** or __text__
        result = replace(in: result, pattern: #"\*\*(.+?)\*\*"#, with: "$1")
        result = replace(in: result, pattern: #"__(.+?)__"#, with: "$1")

        // Italic: *text* (but not mid-word underscores like some_var_name)
        result = replace(in: result, pattern: #"(?<!\w)\*(.+?)\*(?!\w)"#, with: "$1")
        result = replace(in: result, pattern: #"(?<!\w)_(.+?)_(?!\w)"#, with: "$1")

        // Strikethrough: ~~text~~
        result = replace(in: result, pattern: #"~~(.+?)~~"#, with: "$1")

        return result
    }

    private func removeInlineCode(_ text: String) -> String {
        // `code` -> code
        return replace(in: text, pattern: #"`([^`]+)`"#, with: "$1")
    }

    private func removeHeaders(_ text: String) -> String {
        // # Header -> Header (with newline for paragraph break)
        let pattern = #"(?m)^#{1,6}\s+(.+)$"#
        return replace(in: text, pattern: pattern, with: "\n$1\n")
    }

    private func removeBlockquotes(_ text: String) -> String {
        // > quoted text -> quoted text (can be nested)
        let pattern = #"(?m)^(?:>\s?)+"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeHorizontalRules(_ text: String) -> String {
        // ---, ***, ___ (3 or more)
        let pattern = #"(?m)^[-*_]{3,}\s*$"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeListMarkers(_ text: String) -> String {
        var result = text

        // Unordered: - item, * item, + item (with optional indentation)
        let unorderedPattern = #"(?m)^[\t ]*[-*+]\s+"#
        result = replace(in: result, pattern: unorderedPattern, with: "")

        // Ordered: 1. item, 2. item (with optional indentation)
        let orderedPattern = #"(?m)^[\t ]*\d+\.\s+"#
        result = replace(in: result, pattern: orderedPattern, with: "")

        return result
    }

    private func removeFootnoteReferences(_ text: String) -> String {
        // [^1], [^note] inline references
        let pattern = #"\[\^[^\]]+\]"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeFootnoteDefinitions(_ text: String) -> String {
        // [^1]: Definition text (at start of line)
        let pattern = #"(?m)^\[\^[^\]]+\]:\s+.*$"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func removeInlineHTML(_ text: String) -> String {
        let pattern = #"<[^>]+>"#
        return replace(in: text, pattern: pattern, with: "")
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&mdash;", ","),
            ("&ndash;", "-"),
            ("&hellip;", "..."),
            ("&lsquo;", "'"),
            ("&rsquo;", "'"),
            ("&ldquo;", "\""),
            ("&rdquo;", "\""),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric entities: &#123; or &#x7B;
        result = replaceWithClosure(in: result, pattern: #"&#(\d+);"#) { match in
            if let numStr = match.group(1), let num = Int(numStr), let scalar = Unicode.Scalar(num) {
                return String(Character(scalar))
            }
            return match.fullMatch
        }
        result = replaceWithClosure(in: result, pattern: #"&#x([0-9a-fA-F]+);"#) { match in
            if let hexStr = match.group(1), let num = UInt32(hexStr, radix: 16),
               let scalar = Unicode.Scalar(num) {
                return String(Character(scalar))
            }
            return match.fullMatch
        }

        return result
    }

    private func normalizeWhitespace(_ text: String) -> String {
        var result = text

        // Collapse 3+ newlines to 2
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Collapse multiple spaces to single
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Remove spaces at start of lines
        result = replace(in: result, pattern: #"(?m)^ +"#, with: "")

        return result
    }

    // MARK: - Regex Helpers

    private func replace(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private func replaceWithClosure(
        in text: String,
        pattern: String,
        replacer: (RegexMatch) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        var result = text
        // Process matches in reverse order to preserve indices
        for match in matches.reversed() {
            let fullRange = Range(match.range, in: result)!
            let fullMatch = String(result[fullRange])

            var groups: [String?] = []
            for groupIndex in 0..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: groupIndex), in: result) {
                    groups.append(String(result[groupRange]))
                } else {
                    groups.append(nil)
                }
            }

            let regexMatch = RegexMatch(fullMatch: fullMatch, groups: groups)
            let replacement = replacer(regexMatch)
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }
}

// MARK: - Regex Match Helper

/// Simple container for regex match results used by the closure-based replacement
private struct RegexMatch {
    let fullMatch: String
    let groups: [String?]

    func group(_ index: Int) -> String? {
        guard index < groups.count else { return nil }
        return groups[index]
    }
}
