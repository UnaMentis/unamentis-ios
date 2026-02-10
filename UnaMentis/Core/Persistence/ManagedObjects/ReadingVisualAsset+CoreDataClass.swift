// UnaMentis - ReadingVisualAsset Core Data Class
// Manual NSManagedObject subclass for SPM compatibility
//
// Stores images extracted from PDFs during import, mapped to reading chunks
// for synchronized display during TTS playback.

import Foundation
import CoreData

@objc(ReadingVisualAsset)
public class ReadingVisualAsset: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ReadingVisualAsset> {
        return NSFetchRequest<ReadingVisualAsset>(entityName: "ReadingVisualAsset")
    }

    // MARK: - Core Attributes

    @NSManaged public var id: UUID?
    @NSManaged public var chunkIndex: Int32
    @NSManaged public var pageIndex: Int32
    @NSManaged public var positionOnPage: Float
    @NSManaged public var mimeType: String?
    @NSManaged public var width: Int32
    @NSManaged public var height: Int32
    @NSManaged public var altText: String?
    @NSManaged public var cachedData: Data?
    @NSManaged public var localPath: String?

    // MARK: - Relationships

    @NSManaged public var readingItem: ReadingListItem?

    // MARK: - Initialization Helper

    /// Configure a new ReadingVisualAsset with required fields
    public func configure(
        chunkIndex: Int32,
        pageIndex: Int32,
        positionOnPage: Float,
        width: Int32,
        height: Int32,
        mimeType: String = "image/png",
        altText: String? = nil,
        localPath: String? = nil
    ) {
        self.id = UUID()
        self.chunkIndex = chunkIndex
        self.pageIndex = pageIndex
        self.positionOnPage = positionOnPage
        self.width = width
        self.height = height
        self.mimeType = mimeType
        self.altText = altText
        self.localPath = localPath
    }
}

// MARK: - Identifiable Conformance

extension ReadingVisualAsset: Identifiable { }

// NOTE: Do NOT override hash/isEqual on NSManagedObject subclasses!
// Core Data uses these internally for object tracking and faulting.
