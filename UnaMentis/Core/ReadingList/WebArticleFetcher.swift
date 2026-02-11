// UnaMentis - WebArticleFetcher
// Fetches web pages and extracts article content for reading list import.
//
// Part of Core/ReadingList

import Foundation
import Logging

// MARK: - Web Article Content

/// Content extracted from a web article
public struct WebArticleContent: Sendable {
    public let url: URL
    public let title: String?
    public let author: String?
    public let text: String
    public let fetchedAt: Date
}

// MARK: - Web Article Fetcher

/// Actor responsible for fetching web pages and extracting article content
public actor WebArticleFetcher {

    // MARK: - Properties

    private let session: URLSession
    private let extractor: HTMLArticleExtractor
    private let logger = Logger(label: "com.unamentis.readinglist.webfetcher")

    /// Maximum response size (5 MB)
    private static let maxResponseSize = 5 * 1024 * 1024

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        self.extractor = HTMLArticleExtractor()
    }

    // MARK: - Fetch Operations

    /// Fetch and extract article content from a URL
    /// - Parameter url: The web page URL to fetch
    /// - Returns: Extracted article content
    /// - Throws: WebFetchError on failure
    public func fetchArticle(from url: URL) async throws -> WebArticleContent {
        // Validate URL scheme
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw WebFetchError.invalidURL("Only HTTP and HTTPS URLs are supported")
        }

        logger.info("Fetching article from: \(url.absoluteString)")

        // Build request with appropriate headers
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        // Fetch the page
        let (data, response) = try await session.data(for: request)

        // Validate response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.fetchFailed("Invalid server response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebFetchError.fetchFailed("HTTP \(httpResponse.statusCode)")
        }

        // Check content size
        guard data.count <= Self.maxResponseSize else {
            throw WebFetchError.contentTooLarge
        }

        // Check content type
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
            let lowerContentType = contentType.lowercased()
            guard lowerContentType.contains("text/html")
                || lowerContentType.contains("application/xhtml")
                || lowerContentType.contains("text/plain") else {
                throw WebFetchError.unsupportedContentType(contentType)
            }
        }

        // Decode HTML string
        let html = decodeHTML(data: data, response: httpResponse)

        guard !html.isEmpty else {
            throw WebFetchError.fetchFailed("Empty response from server")
        }

        // Extract article content
        let result = extractor.extractArticle(from: html, url: url)

        guard !result.text.isEmpty else {
            throw WebFetchError.noArticleContent
        }

        // Validate minimum content length (avoid importing navigation-only pages)
        guard result.text.count >= 100 else {
            throw WebFetchError.noArticleContent
        }

        logger.info(
            "Extracted article: \(result.title ?? "untitled"), \(result.text.count) characters"
        )

        return WebArticleContent(
            url: url,
            title: result.title,
            author: result.author,
            text: result.text,
            fetchedAt: Date()
        )
    }

    // MARK: - Private Helpers

    /// Decode HTML data to string, detecting encoding from HTTP headers
    private func decodeHTML(data: Data, response: HTTPURLResponse) -> String {
        // Try to detect encoding from Content-Type header
        if let contentType = response.value(forHTTPHeaderField: "Content-Type") {
            let encoding = detectEncoding(from: contentType)
            if let html = String(data: data, encoding: encoding) {
                return html
            }
        }

        // Try UTF-8
        if let html = String(data: data, encoding: .utf8) {
            return html
        }

        // Try ISO Latin 1 as last resort
        if let html = String(data: data, encoding: .isoLatin1) {
            return html
        }

        return ""
    }

    /// Detect string encoding from Content-Type header value
    private func detectEncoding(from contentType: String) -> String.Encoding {
        let lower = contentType.lowercased()

        if lower.contains("charset=utf-8") {
            return .utf8
        } else if lower.contains("charset=iso-8859-1") || lower.contains("charset=latin1") {
            return .isoLatin1
        } else if lower.contains("charset=windows-1252") {
            return .windowsCP1252
        } else if lower.contains("charset=ascii") {
            return .ascii
        }

        // Default to UTF-8
        return .utf8
    }
}

// MARK: - Web Fetch Errors

/// Errors that can occur during web article fetching
public enum WebFetchError: LocalizedError {
    case invalidURL(String)
    case fetchFailed(String)
    case contentTooLarge
    case unsupportedContentType(String)
    case noArticleContent

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let reason):
            return "Invalid URL: \(reason)"
        case .fetchFailed(let reason):
            return "Failed to fetch page: \(reason)"
        case .contentTooLarge:
            return "The page is too large to import (max 5 MB)"
        case .unsupportedContentType(let type):
            return "Unsupported content type: \(type). Only HTML pages can be imported."
        case .noArticleContent:
            return "No readable article content found on this page"
        }
    }
}
