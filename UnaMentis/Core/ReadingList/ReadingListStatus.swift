// UnaMentis - ReadingListStatus
// Enum for reading list item status
//
// Part of Core/ReadingList

import Foundation
import SwiftUI

// MARK: - Reading List Status

/// The status of a reading list item
public enum ReadingListStatus: String, Codable, Sendable, CaseIterable {
    case unread = "unread"
    case inProgress = "in_progress"
    case completed = "completed"
    case archived = "archived"

    // MARK: - Display Properties

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .unread: return "Unread"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }

    /// SF Symbol icon name
    public var iconName: String {
        switch self {
        case .unread: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }

    /// Icon color
    public var iconColor: Color {
        switch self {
        case .unread: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .archived: return .gray
        }
    }

    // MARK: - State Properties

    /// Whether this status represents an active (visible in main list) item
    public var isActive: Bool {
        self == .unread || self == .inProgress
    }

    /// Whether this item can be played
    public var isPlayable: Bool {
        self != .archived
    }

    /// Sort priority (lower = higher in list)
    public var sortPriority: Int {
        switch self {
        case .inProgress: return 0
        case .unread: return 1
        case .completed: return 2
        case .archived: return 3
        }
    }
}

// MARK: - Audio Pre-generation Status

/// Status of first-chunk audio pre-generation for a reading list item
public enum AudioPreGenStatus: String, Codable, Sendable {
    /// No pre-generation attempted
    case none = "none"
    /// Pre-generation is in progress
    case generating = "generating"
    /// Pre-generated audio is ready for instant playback
    case ready = "ready"
    /// Pre-generation failed (will fall back to streaming)
    case failed = "failed"
}
