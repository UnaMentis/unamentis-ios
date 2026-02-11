// UnaMentis - ReadingListSourceType
// Enum for reading list document source types
//
// Part of Core/ReadingList

import Foundation
import SwiftUI

// MARK: - Reading List Source Type

/// The source type of a reading list document
public enum ReadingListSourceType: String, Codable, Sendable, CaseIterable {
    case pdf = "pdf"
    case plainText = "text"
    case markdown = "markdown"
    case webArticle = "web_article"

    // MARK: - Display Properties

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .pdf: return "PDF Document"
        case .plainText: return "Plain Text"
        case .markdown: return "Markdown"
        case .webArticle: return "Web Article"
        }
    }

    /// SF Symbol icon name
    public var iconName: String {
        switch self {
        case .pdf: return "doc.fill"
        case .plainText: return "doc.text.fill"
        case .markdown: return "doc.richtext.fill"
        case .webArticle: return "globe"
        }
    }

    /// Icon color
    public var iconColor: Color {
        switch self {
        case .pdf: return .red
        case .plainText: return .blue
        case .markdown: return .purple
        case .webArticle: return .orange
        }
    }

    // MARK: - File Extensions

    /// Supported file extensions for this type
    public var fileExtensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .plainText: return ["txt", "text"]
        case .markdown: return ["md", "markdown"]
        case .webArticle: return []
        }
    }

    /// Detect source type from file extension
    public static func from(fileExtension: String) -> ReadingListSourceType? {
        let ext = fileExtension.lowercased()
        for sourceType in allCases {
            if sourceType.fileExtensions.contains(ext) {
                return sourceType
            }
        }
        return nil
    }

    /// Detect source type from URL
    public static func from(url: URL) -> ReadingListSourceType? {
        return from(fileExtension: url.pathExtension)
    }
}
