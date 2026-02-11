// UnaMentis - MarkdownStripper Tests
// Tests for markdown-to-plaintext conversion used in reading list TTS

import XCTest
@testable import UnaMentis

final class MarkdownStripperTests: XCTestCase {

    var stripper: MarkdownStripper!

    override func setUp() {
        super.setUp()
        stripper = MarkdownStripper()
    }

    override func tearDown() {
        stripper = nil
        super.tearDown()
    }

    // MARK: - Headers

    func testStripHeaders() {
        XCTAssertTrue(stripper.stripMarkdown("# Title").contains("Title"))
        XCTAssertTrue(stripper.stripMarkdown("## Subtitle").contains("Subtitle"))
        XCTAssertTrue(stripper.stripMarkdown("### Section").contains("Section"))
        XCTAssertFalse(stripper.stripMarkdown("# Title").contains("#"))
    }

    // MARK: - Bold, Italic, Strikethrough

    func testStripBold() {
        XCTAssertEqual(stripper.stripMarkdown("This is **bold** text"), "This is bold text")
        XCTAssertEqual(stripper.stripMarkdown("This is __bold__ text"), "This is bold text")
    }

    func testStripItalic() {
        XCTAssertEqual(stripper.stripMarkdown("This is *italic* text"), "This is italic text")
        XCTAssertEqual(stripper.stripMarkdown("This is _italic_ text"), "This is italic text")
        // Mid-word underscores should NOT be stripped (e.g., variable names)
        XCTAssertTrue(stripper.stripMarkdown("some_var_name").contains("some_var_name"))
    }

    func testStripBoldItalic() {
        XCTAssertEqual(
            stripper.stripMarkdown("This is ***bold italic*** text"),
            "This is bold italic text"
        )
    }

    func testStripStrikethrough() {
        XCTAssertEqual(
            stripper.stripMarkdown("This is ~~deleted~~ text"),
            "This is deleted text"
        )
    }

    // MARK: - Links

    func testStripInlineLinks() {
        XCTAssertEqual(
            stripper.stripMarkdown("Visit [Google](https://google.com) today"),
            "Visit Google today"
        )
    }

    func testStripReferenceLinks() {
        let md = """
        Visit [Google][1] today.

        [1]: https://google.com
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("Visit Google today."))
        XCTAssertFalse(result.contains("https://"))
    }

    // MARK: - Images

    func testStripImagesWithAltText() {
        let result = stripper.stripMarkdown("Check ![A photo](image.png) here")
        XCTAssertTrue(result.contains("A photo"))
        XCTAssertFalse(result.contains("image.png"))
    }

    func testStripImagesWithoutAltText() {
        let result = stripper.stripMarkdown("Before ![](image.png) after")
        XCTAssertFalse(result.contains("image.png"))
    }

    // MARK: - Code

    func testStripInlineCode() {
        XCTAssertEqual(
            stripper.stripMarkdown("Use `print()` to log"),
            "Use print() to log"
        )
    }

    func testStripFencedCodeBlocks() {
        let md = """
        Before code:

        ```python
        print("hello")
        ```

        After code.
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("Before code:"))
        XCTAssertTrue(result.contains("After code."))
        XCTAssertFalse(result.contains("```"))
    }

    // MARK: - Lists

    func testStripUnorderedListMarkers() {
        let md = """
        - First item
        - Second item
        * Third item
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("First item"))
        XCTAssertTrue(result.contains("Second item"))
        XCTAssertTrue(result.contains("Third item"))
        XCTAssertFalse(result.hasPrefix("-"))
    }

    func testStripOrderedListMarkers() {
        let md = """
        1. First
        2. Second
        3. Third
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("First"))
        XCTAssertTrue(result.contains("Second"))
        XCTAssertFalse(result.contains("1."))
    }

    // MARK: - Blockquotes

    func testStripBlockquotes() {
        let md = "> This is a quote"
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("This is a quote"))
        XCTAssertFalse(result.hasPrefix(">"))
    }

    // MARK: - Horizontal Rules

    func testStripHorizontalRules() {
        let md = """
        Above

        ---

        Below
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("Above"))
        XCTAssertTrue(result.contains("Below"))
        XCTAssertFalse(result.contains("---"))
    }

    // MARK: - Front Matter

    func testStripYAMLFrontMatter() {
        let md = """
        ---
        title: My Post
        date: 2024-01-01
        ---

        Actual content here.
        """
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("Actual content here."))
        XCTAssertFalse(result.contains("title: My Post"))
    }

    // MARK: - HTML

    func testStripHTMLComments() {
        let md = "Before <!-- hidden --> After"
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("Before"))
        XCTAssertTrue(result.contains("After"))
        XCTAssertFalse(result.contains("hidden"))
    }

    func testStripInlineHTML() {
        let md = "This has <strong>HTML</strong> in it"
        let result = stripper.stripMarkdown(md)
        XCTAssertTrue(result.contains("HTML"))
        XCTAssertFalse(result.contains("<strong>"))
    }

    // MARK: - HTML Entities

    func testDecodeHTMLEntities() {
        XCTAssertEqual(stripper.stripMarkdown("Fish &amp; Chips"), "Fish & Chips")
        XCTAssertTrue(stripper.stripMarkdown("A &gt; B").contains("A > B"))
    }

    // MARK: - Footnotes

    func testStripFootnoteReferences() {
        let result = stripper.stripMarkdown("Important claim[^1] here.")
        XCTAssertTrue(result.contains("Important claim here."))
        XCTAssertFalse(result.contains("[^1]"))
    }

    // MARK: - Complex Document

    func testComplexMarkdownDocument() {
        let md = """
        ---
        title: Test
        ---

        # The Main Title

        This is a **bold** statement with [a link](https://example.com).

        ## Section Two

        > A famous quote

        - Point one
        - Point two with `code`

        Here is ~~deleted~~ text and *italic* emphasis.

        ---

        ### Final Section

        More content here[^1].

        [^1]: This is a footnote.
        """

        let result = stripper.stripMarkdown(md)

        // Content preserved
        XCTAssertTrue(result.contains("The Main Title"))
        XCTAssertTrue(result.contains("bold statement"))
        XCTAssertTrue(result.contains("a link"))
        XCTAssertTrue(result.contains("A famous quote"))
        XCTAssertTrue(result.contains("Point one"))
        XCTAssertTrue(result.contains("code"))
        XCTAssertTrue(result.contains("deleted text"))
        XCTAssertTrue(result.contains("italic emphasis"))
        XCTAssertTrue(result.contains("More content here"))

        // Syntax removed
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("[a link]"))
        XCTAssertFalse(result.contains("https://"))
        XCTAssertFalse(result.contains(">"))
        XCTAssertFalse(result.contains("~~"))
        XCTAssertFalse(result.contains("[^1]"))
        XCTAssertFalse(result.contains("title: Test"))
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        XCTAssertEqual(stripper.stripMarkdown(""), "")
    }

    func testPlainTextPassthrough() {
        let plain = "Just regular text with no markdown."
        XCTAssertEqual(stripper.stripMarkdown(plain), plain)
    }

    func testWhitespaceNormalization() {
        let md = "Too    many   spaces\n\n\n\nToo many lines"
        let result = stripper.stripMarkdown(md)
        XCTAssertFalse(result.contains("  "))
        XCTAssertFalse(result.contains("\n\n\n"))
    }
}
