// UnaMentis - ReadingTextChunker
// Import-time text segmentation for low-latency TTS playback
//
// Chunks are created during document import, NOT at playback time.
// This enables instant playback and pre-buffering of audio.
//
// Part of Core/ReadingList

import Foundation
import PDFKit
import UIKit
import Logging

// MARK: - Chunking Configuration

/// Configuration for text chunking
public struct ChunkingConfig: Sendable {
    /// Target words per chunk (TTS optimized)
    /// At ~150 WPM speaking rate, 30-50 words = 12-20 seconds per chunk
    public let targetWordsPerChunk: Int

    /// Maximum words per chunk (hard limit)
    public let maxWordsPerChunk: Int

    /// Minimum words per chunk (avoid tiny chunks)
    public let minWordsPerChunk: Int

    /// Default configuration optimized for TTS playback
    public static let `default` = ChunkingConfig(
        targetWordsPerChunk: 40,
        maxWordsPerChunk: 60,
        minWordsPerChunk: 15
    )

    /// Shorter chunks for faster response time
    public static let shortChunks = ChunkingConfig(
        targetWordsPerChunk: 25,
        maxWordsPerChunk: 40,
        minWordsPerChunk: 10
    )

    /// Longer chunks for smoother listening
    public static let longChunks = ChunkingConfig(
        targetWordsPerChunk: 60,
        maxWordsPerChunk: 80,
        minWordsPerChunk: 20
    )

    public init(targetWordsPerChunk: Int, maxWordsPerChunk: Int, minWordsPerChunk: Int) {
        self.targetWordsPerChunk = targetWordsPerChunk
        self.maxWordsPerChunk = maxWordsPerChunk
        self.minWordsPerChunk = minWordsPerChunk
    }
}

// MARK: - Chunk Result

/// A pre-segmented text chunk ready for TTS
public struct TextChunkResult: Sendable {
    public let index: Int
    public let text: String
    public let characterOffset: Int64
    public let estimatedDurationSeconds: Float

    public init(index: Int, text: String, characterOffset: Int64, estimatedDurationSeconds: Float) {
        self.index = index
        self.text = text
        self.characterOffset = characterOffset
        self.estimatedDurationSeconds = estimatedDurationSeconds
    }
}

// MARK: - PDF Image Extraction Types

/// An image extracted from a PDF, mapped to a specific reading chunk
public struct MappedPDFImage: Sendable {
    public let chunkIndex: Int
    public let pageIndex: Int
    public let positionOnPage: Float
    public let imageData: Data
    public let width: Int
    public let height: Int
}

/// Result of processing a PDF with both text chunks and images
public struct PDFProcessingResult: Sendable {
    public let chunks: [TextChunkResult]
    public let images: [MappedPDFImage]
}

/// Raw image data extracted from a PDF page before chunk mapping
private struct RawPDFImage {
    let pageIndex: Int
    let positionOnPage: Float
    let data: Data
    let width: Int
    let height: Int
}

// MARK: - CGPDF Dictionary Key Collector

/// Collects keys from a CGPDFDictionary via CGPDFDictionaryApplyFunction
private final class PDFDictionaryKeyCollector {
    var keys: [String] = []
}

/// C function pointer for enumerating CGPDFDictionary keys
private let collectPDFDictionaryKeys: CGPDFDictionaryApplierFunction = { key, _, info in
    guard let info else { return }
    let collector = Unmanaged<PDFDictionaryKeyCollector>
        .fromOpaque(info).takeUnretainedValue()
    collector.keys.append(String(cString: key))
}

// MARK: - Reading Text Chunker

/// Actor responsible for chunking text at natural TTS boundaries
///
/// Chunking happens at import time to enable:
/// - Instant playback (no parsing delay when pressing play)
/// - Pre-buffering of upcoming audio chunks
/// - Easy position tracking and seeking
public actor ReadingTextChunker {

    // MARK: - Properties

    private let logger = Logger(label: "com.unamentis.readinglist.chunker")
    private let config: ChunkingConfig

    /// Average speaking rate in words per second (150 WPM = 2.5 WPS)
    private let wordsPerSecond: Float = 2.5

    // MARK: - Initialization

    public init(config: ChunkingConfig = .default) {
        self.config = config
    }

    // MARK: - Text Extraction

    /// Extract text from a file URL based on source type
    /// - Parameters:
    ///   - url: File URL to extract from
    ///   - sourceType: The type of source file
    /// - Returns: Extracted text content
    public func extractText(from url: URL, sourceType: ReadingListSourceType) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadingChunkerError.fileNotFound(url)
        }

        switch sourceType {
        case .pdf:
            return try extractPDFText(from: url)
        case .plainText:
            return try extractPlainText(from: url)
        }
    }

    /// Extract text from a PDF file
    private func extractPDFText(from url: URL) throws -> String {
        guard let pdfDocument = PDFDocument(url: url) else {
            throw ReadingChunkerError.pdfLoadFailed(url)
        }

        var text = ""
        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex),
                  let pageText = page.string else {
                continue
            }
            text += pageText + "\n\n"
        }

        guard !text.isEmpty else {
            throw ReadingChunkerError.extractionFailed("PDF contains no extractable text")
        }

        return cleanText(text)
    }

    /// Extract text from a plain text file
    private func extractPlainText(from url: URL) throws -> String {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return cleanText(text)
        } catch {
            throw ReadingChunkerError.extractionFailed("Failed to read text file: \(error.localizedDescription)")
        }
    }

    /// Clean and normalize text
    private func cleanText(_ text: String) -> String {
        // Normalize whitespace
        var cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Collapse multiple newlines to max 2
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Collapse multiple spaces to single space
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking

    /// Chunk text into TTS-ready segments
    /// - Parameter text: Full text to chunk
    /// - Returns: Array of chunks with metadata
    public func chunkText(_ text: String) -> [TextChunkResult] {
        guard !text.isEmpty else { return [] }

        // Split into sentences first
        let sentences = splitIntoSentences(text)
        guard !sentences.isEmpty else { return [] }

        logger.debug("Split text into \(sentences.count) sentences")

        // Group sentences into chunks
        var chunks: [TextChunkResult] = []
        var currentChunkSentences: [String] = []
        var currentWordCount = 0
        var characterOffset: Int64 = 0

        for sentence in sentences {
            let sentenceWordCount = sentence.split(separator: " ").count

            // Check if adding this sentence would exceed max
            if currentWordCount + sentenceWordCount > config.maxWordsPerChunk && !currentChunkSentences.isEmpty {
                // Output current chunk
                let chunkText = currentChunkSentences.joined(separator: " ")
                let chunk = TextChunkResult(
                    index: chunks.count,
                    text: chunkText,
                    characterOffset: characterOffset,
                    estimatedDurationSeconds: estimateDuration(wordCount: currentWordCount)
                )
                chunks.append(chunk)

                // Update offset
                characterOffset += Int64(chunkText.count + 1) // +1 for space/newline

                // Start new chunk
                currentChunkSentences = [sentence]
                currentWordCount = sentenceWordCount
            } else {
                // Add to current chunk
                currentChunkSentences.append(sentence)
                currentWordCount += sentenceWordCount

                // If we've reached target size and this is a good break point, output
                if currentWordCount >= config.targetWordsPerChunk {
                    let chunkText = currentChunkSentences.joined(separator: " ")
                    let chunk = TextChunkResult(
                        index: chunks.count,
                        text: chunkText,
                        characterOffset: characterOffset,
                        estimatedDurationSeconds: estimateDuration(wordCount: currentWordCount)
                    )
                    chunks.append(chunk)

                    characterOffset += Int64(chunkText.count + 1)
                    currentChunkSentences = []
                    currentWordCount = 0
                }
            }
        }

        // Output remaining sentences as final chunk
        if !currentChunkSentences.isEmpty {
            let chunkText = currentChunkSentences.joined(separator: " ")
            // Merge with previous chunk if too small
            if currentWordCount < config.minWordsPerChunk && !chunks.isEmpty {
                var lastChunk = chunks.removeLast()
                let mergedText = lastChunk.text + " " + chunkText
                let mergedWordCount = mergedText.split(separator: " ").count
                let mergedChunk = TextChunkResult(
                    index: lastChunk.index,
                    text: mergedText,
                    characterOffset: lastChunk.characterOffset,
                    estimatedDurationSeconds: estimateDuration(wordCount: mergedWordCount)
                )
                chunks.append(mergedChunk)
            } else {
                let chunk = TextChunkResult(
                    index: chunks.count,
                    text: chunkText,
                    characterOffset: characterOffset,
                    estimatedDurationSeconds: estimateDuration(wordCount: currentWordCount)
                )
                chunks.append(chunk)
            }
        }

        logger.info("Created \(chunks.count) chunks from text")
        return chunks
    }

    /// Split text into sentences
    private func splitIntoSentences(_ text: String) -> [String] {
        // Use linguistic tagger for sentence detection
        var sentences: [String] = []

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        // Fallback if linguistic tagger returns nothing
        if sentences.isEmpty {
            // Simple fallback: split on sentence-ending punctuation
            let pattern = #"(?<=[.!?])\s+"#
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(text.startIndex..., in: text)

            var lastEnd = text.startIndex
            regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let matchRange = match?.range,
                   let swiftRange = Range(matchRange, in: text) {
                    let sentence = String(text[lastEnd..<swiftRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty {
                        sentences.append(sentence)
                    }
                    lastEnd = swiftRange.upperBound
                }
            }

            // Add remaining text as final sentence
            let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }
        }

        return sentences
    }

    /// Estimate duration in seconds for a word count
    private func estimateDuration(wordCount: Int) -> Float {
        Float(wordCount) / wordsPerSecond
    }

    // MARK: - Full Import Pipeline

    /// Extract text and chunk in one operation
    /// - Parameters:
    ///   - url: File URL to process
    ///   - sourceType: The type of source file
    /// - Returns: Array of chunks ready for Core Data
    public func processDocument(from url: URL, sourceType: ReadingListSourceType) throws -> [TextChunkResult] {
        logger.info("Processing document: \(url.lastPathComponent)")

        let text = try extractText(from: url, sourceType: sourceType)
        logger.debug("Extracted \(text.count) characters")

        let chunks = chunkText(text)
        logger.info("Document chunked into \(chunks.count) segments")

        return chunks
    }

    // MARK: - PDF Image Extraction

    /// Minimum pixel dimension for extracted images (skip icons/decorations)
    private static let minImageDimension = 20
    /// Maximum output dimension (downscale larger images)
    private static let maxImageDimension: CGFloat = 1024
    /// Maximum total images per document
    private static let maxImagesPerDocument = 100

    /// Extract text and images from a PDF, mapping images to chunks
    /// - Parameters:
    ///   - url: File URL to process
    ///   - sourceType: The type of source file
    /// - Returns: Chunks and mapped images
    public func processDocumentWithImages(
        from url: URL,
        sourceType: ReadingListSourceType
    ) throws -> PDFProcessingResult {
        logger.info("Processing document with images: \(url.lastPathComponent)")

        // Non-PDF sources have no inline images
        guard sourceType == .pdf else {
            let chunks = try processDocument(from: url, sourceType: sourceType)
            return PDFProcessingResult(chunks: chunks, images: [])
        }

        guard let pdfDocument = PDFDocument(url: url) else {
            throw ReadingChunkerError.pdfLoadFailed(url)
        }

        // Extract text with per-page character boundaries
        var fullText = ""
        var pageBoundaries: [(pageIndex: Int, charStart: Int64, charEnd: Int64)] = []

        for pageIndex in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: pageIndex),
                  let pageText = page.string else { continue }

            let start = Int64(fullText.count)
            fullText += pageText + "\n\n"
            let end = Int64(fullText.count)
            pageBoundaries.append((pageIndex: pageIndex, charStart: start, charEnd: end))
        }

        guard !fullText.isEmpty else {
            throw ReadingChunkerError.extractionFailed("PDF contains no extractable text")
        }

        let cleanedText = cleanText(fullText)
        let chunks = chunkText(cleanedText)

        // Extract images from PDF pages
        let rawImages = extractPDFImages(from: pdfDocument)
        logger.info("Extracted \(rawImages.count) images from PDF")

        // Map images to chunks using page boundaries
        let mappedImages = mapImagesToChunks(
            images: rawImages,
            chunks: chunks,
            pageBoundaries: pageBoundaries
        )

        return PDFProcessingResult(chunks: chunks, images: mappedImages)
    }

    /// Extract images from all pages of a PDF
    private func extractPDFImages(
        from pdfDocument: PDFDocument
    ) -> [RawPDFImage] {
        var allImages: [RawPDFImage] = []

        for pageIndex in 0..<pdfDocument.pageCount {
            guard allImages.count < Self.maxImagesPerDocument else { break }
            guard let page = pdfDocument.page(at: pageIndex),
                  let cgPage = page.pageRef else { continue }

            let pageImages = extractImagesFromPage(cgPage: cgPage, pageIndex: pageIndex)
            allImages.append(contentsOf: pageImages)
        }

        return allImages
    }

    /// Extract image XObjects from a single PDF page
    private func extractImagesFromPage(
        cgPage: CGPDFPage,
        pageIndex: Int
    ) -> [RawPDFImage] {
        var images: [RawPDFImage] = []

        guard let pageDict = cgPage.dictionary else { return images }

        var resourcesRef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resourcesRef),
              let resources = resourcesRef else { return images }

        var xObjectRef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjectRef),
              let xObjects = xObjectRef else { return images }

        // Collect all keys from the XObject dictionary
        let collector = PDFDictionaryKeyCollector()
        let info = Unmanaged.passUnretained(collector).toOpaque()
        CGPDFDictionaryApplyFunction(xObjects, collectPDFDictionaryKeys, info)

        // Process each XObject to find images
        var imageIndex = 0
        for key in collector.keys {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xObjects, key, &stream),
                  let stream else { continue }
            guard let streamDict = CGPDFStreamGetDictionary(stream) else { continue }

            // Verify this XObject is an image
            var subtypePtr: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtypePtr),
                  let subtype = subtypePtr,
                  String(cString: subtype) == "Image" else { continue }

            // Get dimensions
            var width: CGPDFInteger = 0
            var height: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(streamDict, "Width", &width)
            CGPDFDictionaryGetInteger(streamDict, "Height", &height)

            guard width >= Self.minImageDimension, height >= Self.minImageDimension else { continue }

            // Extract and optionally downscale the image
            if let result = extractImageData(
                from: stream,
                streamDict: streamDict,
                width: Int(width),
                height: Int(height)
            ) {
                let position = Float(imageIndex) / Float(max(collector.keys.count, 1))
                images.append(RawPDFImage(
                    pageIndex: pageIndex,
                    positionOnPage: position,
                    data: result.data,
                    width: result.width,
                    height: result.height
                ))
                imageIndex += 1
            }
        }

        return images
    }

    /// Extract usable image data from a PDF stream
    private func extractImageData(
        from stream: CGPDFStreamRef,
        streamDict: CGPDFDictionaryRef,
        width: Int,
        height: Int
    ) -> (data: Data, width: Int, height: Int)? {
        var format: CGPDFDataFormat = .raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let rawData = cfData as Data

        // JPEG data: create UIImage directly
        if format == .jpegEncoded {
            guard let uiImage = UIImage(data: rawData) else {
                return (data: rawData, width: width, height: height)
            }
            return downscaleIfNeeded(image: uiImage, originalWidth: width, originalHeight: height)
        }

        // Raw pixel data: reconstruct a CGImage
        var bitsPerComponent: CGPDFInteger = 8
        CGPDFDictionaryGetInteger(streamDict, "BitsPerComponent", &bitsPerComponent)

        let componentsPerPixel = detectColorComponents(from: streamDict)
        let bytesPerRow = width * componentsPerPixel * Int(bitsPerComponent) / 8

        // Validate data size
        let expectedSize = bytesPerRow * height
        guard rawData.count >= expectedSize else {
            logger.debug("Image data size mismatch: expected \(expectedSize), got \(rawData.count)")
            return nil
        }

        guard let provider = CGDataProvider(data: rawData as CFData) else { return nil }

        let colorSpace: CGColorSpace
        switch componentsPerPixel {
        case 1: colorSpace = CGColorSpaceCreateDeviceGray()
        default: colorSpace = CGColorSpaceCreateDeviceRGB()
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: Int(bitsPerComponent),
            bitsPerPixel: Int(bitsPerComponent) * componentsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        return downscaleIfNeeded(image: uiImage, originalWidth: width, originalHeight: height)
    }

    /// Detect number of color components from the PDF color space specification
    private func detectColorComponents(from streamDict: CGPDFDictionaryRef) -> Int {
        var colorSpaceName: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(streamDict, "ColorSpace", &colorSpaceName),
           let name = colorSpaceName {
            switch String(cString: name) {
            case "DeviceGray": return 1
            case "DeviceRGB": return 3
            case "DeviceCMYK": return 4
            default: break
            }
        }
        // Default to RGB for complex/array-based color spaces
        return 3
    }

    /// Downscale an image if it exceeds the maximum dimension, return PNG data
    private func downscaleIfNeeded(
        image: UIImage,
        originalWidth: Int,
        originalHeight: Int
    ) -> (data: Data, width: Int, height: Int)? {
        let maxDim = Self.maxImageDimension
        let scale = min(1.0, maxDim / max(CGFloat(originalWidth), CGFloat(originalHeight)))

        let finalImage: UIImage
        let finalWidth: Int
        let finalHeight: Int

        if scale < 1.0 {
            finalWidth = Int(CGFloat(originalWidth) * scale)
            finalHeight = Int(CGFloat(originalHeight) * scale)
            let newSize = CGSize(width: finalWidth, height: finalHeight)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            finalImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            finalWidth = originalWidth
            finalHeight = originalHeight
            finalImage = image
        }

        guard let pngData = finalImage.pngData() else { return nil }
        return (data: pngData, width: finalWidth, height: finalHeight)
    }

    /// Map extracted images to text chunks using page character boundaries
    private func mapImagesToChunks(
        images: [RawPDFImage],
        chunks: [TextChunkResult],
        pageBoundaries: [(pageIndex: Int, charStart: Int64, charEnd: Int64)]
    ) -> [MappedPDFImage] {
        guard !images.isEmpty, !chunks.isEmpty else { return [] }

        return images.compactMap { image in
            // Find the page boundary for this image's page
            guard let boundary = pageBoundaries.first(
                where: { $0.pageIndex == image.pageIndex }
            ) else { return nil }

            // Estimate character offset proportional to position on page
            let pageCharRange = boundary.charEnd - boundary.charStart
            let estimatedOffset = boundary.charStart
                + Int64(Float(pageCharRange) * image.positionOnPage)

            // Find the chunk containing this character offset
            let chunkIndex = chunks.lastIndex(
                where: { $0.characterOffset <= estimatedOffset }
            ) ?? 0

            return MappedPDFImage(
                chunkIndex: chunkIndex,
                pageIndex: image.pageIndex,
                positionOnPage: image.positionOnPage,
                imageData: image.data,
                width: image.width,
                height: image.height
            )
        }
    }
}

// MARK: - Errors

public enum ReadingChunkerError: LocalizedError {
    case fileNotFound(URL)
    case pdfLoadFailed(URL)
    case extractionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .pdfLoadFailed(let url):
            return "Failed to load PDF: \(url.lastPathComponent)"
        case .extractionFailed(let reason):
            return "Text extraction failed: \(reason)"
        }
    }
}
