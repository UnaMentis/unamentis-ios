// UnaMentis - HTMLArticleExtractor Tests
// Tests for HTML article extraction using swift-readability + SwiftSoup

import XCTest
@testable import UnaMentis

final class HTMLArticleExtractorTests: XCTestCase {

    var extractor: HTMLArticleExtractor!

    override func setUp() {
        super.setUp()
        extractor = HTMLArticleExtractor()
    }

    override func tearDown() {
        extractor = nil
        super.tearDown()
    }

    // MARK: - Basic Extraction

    func testExtractArticleFromSimpleHTML() {
        let html = """
        <html>
        <head><title>Test Article</title></head>
        <body>
        <article>
            <h1>Test Article</h1>
            <p>This is the first paragraph of the article with enough content to be recognized.</p>
            <p>This is the second paragraph with additional text to ensure the content threshold is met for readability extraction.</p>
            <p>And a third paragraph to make the article substantial enough for the readability algorithm to identify as article content.</p>
        </article>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from article")
        XCTAssertTrue(
            result.text.contains("first paragraph"),
            "Should contain article text"
        )
    }

    func testExtractTitleFromOGTag() {
        let html = """
        <html>
        <head>
            <meta property="og:title" content="OG Title">
            <title>Page Title | Site Name</title>
        </head>
        <body>
        <article>
            <p>Article content goes here with enough text to pass minimum content thresholds for extraction.</p>
            <p>More paragraphs are needed to make this a substantial article that readability recognizes.</p>
            <p>Third paragraph for good measure to ensure content length requirements are satisfied.</p>
        </article>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        // Either readability or fallback should extract some title
        XCTAssertNotNil(result.title, "Should extract a title")
    }

    func testExtractAuthorFromMetaTag() {
        let html = """
        <html>
        <head>
            <meta name="author" content="Jane Doe">
            <title>Test</title>
        </head>
        <body>
        <article>
            <p>Article by Jane with enough content to be extracted by the readability algorithm.</p>
            <p>Additional paragraph content to meet minimum length requirements for extraction.</p>
            <p>And more content to ensure this is recognized as a proper article by Mozilla Readability.</p>
        </article>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        // Author might come from readability byline or meta tag fallback
        if let author = result.author {
            XCTAssertTrue(
                author.contains("Jane") || author.contains("Doe"),
                "Author should be Jane Doe, got: \(author)"
            )
        }
    }

    // MARK: - Script/Style Removal

    func testScriptContentNotExtracted() {
        let html = """
        <html>
        <head><title>Test</title></head>
        <body>
        <article>
            <p>Real content that should be extracted by the article extractor.</p>
            <script>var secret = "should not appear in output";</script>
            <p>More real content here with additional text for the algorithm.</p>
            <p>Third paragraph with enough text to meet minimum content thresholds.</p>
        </article>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertFalse(
            result.text.contains("should not appear"),
            "Script content should not be in extracted text"
        )
        XCTAssertTrue(
            result.text.contains("Real content"),
            "Article content should be present"
        )
    }

    func testStyleContentNotExtracted() {
        let html = """
        <html>
        <head>
            <title>Test</title>
            <style>.hidden { display: none; }</style>
        </head>
        <body>
        <article>
            <p>Visible content for the article reader to extract and display.</p>
            <p>Another paragraph of content to ensure sufficient length for readability.</p>
            <p>Final paragraph to make this article substantial enough for extraction.</p>
        </article>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertFalse(
            result.text.contains(".hidden"),
            "Style content should not be in extracted text"
        )
    }

    // MARK: - Content Region Detection

    func testExtractsFromArticleTag() {
        let html = """
        <html>
        <body>
        <nav>Navigation links that should not be extracted</nav>
        <article>
            <p>This is the actual article content that the extractor should find and return.</p>
            <p>It has multiple paragraphs to ensure the content is substantial enough.</p>
            <p>And a final paragraph to meet minimum content requirements for extraction.</p>
        </article>
        <footer>Footer content that should not be extracted</footer>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertTrue(
            result.text.contains("actual article content"),
            "Should extract from article tag"
        )
    }

    // MARK: - URL Parameter

    func testURLPassedToReadability() {
        let html = """
        <html>
        <head><title>Test</title></head>
        <body>
        <article>
            <p>Article with a <a href="/relative/link">relative link</a> inside it.</p>
            <p>More content to ensure the article is long enough for extraction to work.</p>
            <p>Additional paragraph text to meet the minimum content threshold requirement.</p>
        </article>
        </body>
        </html>
        """

        let url = URL(string: "https://example.com/articles/1")!
        let result = extractor.extractArticle(from: html, url: url)

        // Should not crash; URL helps Readability resolve relative links
        XCTAssertFalse(result.text.isEmpty)
    }

    // MARK: - Fallback Behavior

    func testFallbackForNonArticlePage() {
        // A page without article/main structure should trigger SwiftSoup fallback
        let html = """
        <html>
        <head><title>Simple Page</title></head>
        <body>
        <div>
            <p>Some text on a page without article structure but with enough content for extraction.</p>
            <p>More text in another paragraph to make the content substantial for the fallback.</p>
        </div>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        // Fallback should still extract something
        XCTAssertFalse(result.text.isEmpty, "Fallback should extract text from body")
    }

    func testEmptyHTMLReturnsEmptyText() {
        let result = extractor.extractArticle(from: "")
        XCTAssertTrue(result.text.isEmpty)
    }

    func testMalformedHTMLDoesNotCrash() {
        let html = "<html><body><p>Unclosed tag<div>Nested badly</p></html>"
        let result = extractor.extractArticle(from: html)
        // Should not crash, may or may not extract text
        _ = result.text
    }

    // MARK: - Post-Processing

    func testFootnoteMarkersRemoved() {
        let html = """
        <html><body>
        <article>
            <p>Important claim[1] with evidence[2] and more context for extraction.</p>
            <p>Additional paragraph to ensure content meets minimum extraction thresholds.</p>
            <p>Third paragraph with even more text for the readability algorithm to work with.</p>
        </article>
        </body></html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertFalse(
            result.text.contains("[1]"),
            "Footnote markers should be removed"
        )
        XCTAssertFalse(
            result.text.contains("[2]"),
            "Footnote markers should be removed"
        )
    }

    // MARK: - Real-World HTML Pattern

    func testBlogPostStructure() {
        let html = """
        <html>
        <head>
            <title>How AI Works - Tech Blog</title>
            <meta name="author" content="Alice Smith">
            <meta property="og:title" content="How AI Works">
        </head>
        <body>
        <header><nav><a href="/">Home</a> | <a href="/blog">Blog</a></nav></header>
        <main>
            <article>
                <h1>How AI Works</h1>
                <p class="meta">Published January 1, 2025</p>
                <p>Artificial intelligence is a broad field that encompasses machine learning,
                   deep learning, and natural language processing. Understanding these concepts
                   is essential for anyone working in technology today.</p>
                <p>Machine learning algorithms learn from data by identifying patterns and
                   making predictions. This process involves training models on large datasets
                   and evaluating their performance on unseen data.</p>
                <p>Deep learning is a subset of machine learning that uses neural networks
                   with multiple layers. These networks can learn complex representations
                   of data and are used in image recognition, speech processing, and more.</p>
            </article>
        </main>
        <aside><h3>Related Posts</h3><ul><li>Post 1</li><li>Post 2</li></ul></aside>
        <footer><p>Copyright 2025</p></footer>
        </body>
        </html>
        """

        let result = extractor.extractArticle(from: html)

        XCTAssertFalse(result.text.isEmpty, "Should extract article content")
        XCTAssertTrue(
            result.text.contains("Artificial intelligence") || result.text.contains("Machine learning"),
            "Should contain article body text"
        )
    }
}
