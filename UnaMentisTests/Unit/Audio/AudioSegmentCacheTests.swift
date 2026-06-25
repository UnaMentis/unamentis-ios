// UnaMentis - AudioSegmentCache Tests
// Unit tests for the real AudioSegmentCache actor.
//
// Exercises the real per-topic audio segment cache: round-trip storage of
// index/text/audioData, accurate byte and count accounting (including the
// re-cache-same-index-replaces case that must not double-count bytes), the
// hard size limit that refuses over-budget segments, topic-change clearing
// semantics, sorted retrieval (getAllSegments / getSegments(from:)), presence
// checks, the cachedRange min...max contract, and clearCache reset behavior.
//
// No mocks are used. The cache is an internal type with no external API
// dependencies, so a real instance with real Data values is exercised.

import XCTest
@testable import UnaMentis

final class AudioSegmentCacheTests: XCTestCase {

    // MARK: - Round-trip

    func testCacheThenGet_roundTripsIndexTextAndAudioExactly() async {
        let cache = AudioSegmentCache()
        let audio = Data(repeating: 7, count: 64)

        await cache.cacheSegment(index: 3, text: "hello world", audioData: audio)

        let segment = await cache.getSegment(at: 3)
        XCTAssertNotNil(segment, "Cached segment should be retrievable by its index")
        XCTAssertEqual(segment?.index, 3, "Index must round-trip unchanged")
        XCTAssertEqual(segment?.text, "hello world", "Text must round-trip unchanged")
        XCTAssertEqual(segment?.audioData, audio, "Audio data must round-trip byte-for-byte")
    }

    func testGetSegment_returnsNilForUncachedIndex() async {
        let cache = AudioSegmentCache()
        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 10))

        let missing = await cache.getSegment(at: 99)
        XCTAssertNil(missing, "An index that was never cached must return nil")
    }

    // MARK: - Count and byte accounting

    func testInserts_trackCountAndTotalBytesAsSumOfAudioData() async {
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 100))
        await cache.cacheSegment(index: 1, text: "b", audioData: Data(repeating: 0, count: 250))
        await cache.cacheSegment(index: 2, text: "c", audioData: Data(repeating: 0, count: 50))

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        XCTAssertEqual(count, 3, "Three distinct indices should yield a count of 3")
        XCTAssertEqual(bytes, 400, "Total bytes must equal the sum of audioData.count (100 + 250 + 50)")
    }

    func testRecacheSameIndex_replacesAndDoesNotDoubleCountBytes() async {
        // This is the size-accounting bug class the cache must protect against:
        // re-caching the same index must replace, not accumulate.
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 0, text: "first", audioData: Data(repeating: 1, count: 100))
        await cache.cacheSegment(index: 0, text: "second", audioData: Data(repeating: 2, count: 30))

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        let segment = await cache.getSegment(at: 0)

        XCTAssertEqual(count, 1, "Re-caching the same index must not increase the segment count")
        XCTAssertEqual(bytes, 30, "Total bytes must reflect only the replacement size, not 100 + 30")
        XCTAssertEqual(segment?.text, "second", "The replacement segment's text must win")
        XCTAssertEqual(segment?.audioData.count, 30, "The replacement segment's audio must win")
    }

    func testRecacheSameIndexLarger_updatesBytesUpward() async {
        // Replacing with a larger payload must raise the byte total to the new size.
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 5, text: "small", audioData: Data(repeating: 0, count: 40))
        await cache.cacheSegment(index: 5, text: "big", audioData: Data(repeating: 0, count: 200))

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        let segment = await cache.getSegment(at: 5)
        XCTAssertEqual(count, 1, "Still a single segment after replacement")
        XCTAssertEqual(bytes, 200, "Bytes must update to the larger replacement size")
        XCTAssertEqual(segment?.text, "big", "The larger replacement's text must win")
        XCTAssertEqual(segment?.audioData.count, 200, "The larger replacement's audio must win")
    }

    // MARK: - Size limit

    func testCacheLimit_refusesSegmentThatWouldExceedLimit() async {
        // maxCacheBytes = maxCacheMB * 1024 * 1024. With 1 MB the budget is 1,048,576 bytes.
        let cache = AudioSegmentCache(maxCacheMB: 1)
        let limit = 1024 * 1024

        // Fill close to the limit with a segment that fits.
        await cache.cacheSegment(index: 0, text: "fits", audioData: Data(repeating: 0, count: limit - 10))
        let bytesAfterFirst = await cache.totalCachedBytes
        let countAfterFirst = await cache.segmentCount
        XCTAssertEqual(countAfterFirst, 1, "The first under-budget segment should be stored")
        XCTAssertEqual(bytesAfterFirst, limit - 10, "Bytes should reflect the first stored segment")

        // A second segment whose addition crosses the limit must be refused.
        await cache.cacheSegment(index: 1, text: "over", audioData: Data(repeating: 0, count: 100))

        let countAfter = await cache.segmentCount
        let bytesAfter = await cache.totalCachedBytes
        let overflow = await cache.getSegment(at: 1)
        XCTAssertEqual(countAfter, 1, "The over-limit segment must not be stored, count stays 1")
        XCTAssertEqual(bytesAfter, limit - 10, "Total bytes must be unchanged after the refusal")
        XCTAssertNil(overflow, "getSegment must return nil for the refused over-limit segment")
    }

    func testCacheLimit_acceptsSegmentExactlyAtLimit() async {
        // newSize > maxCacheBytes is refused, so newSize == maxCacheBytes is accepted.
        let cache = AudioSegmentCache(maxCacheMB: 1)
        let limit = 1024 * 1024

        await cache.cacheSegment(index: 0, text: "exact", audioData: Data(repeating: 0, count: limit))

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        XCTAssertEqual(count, 1, "A segment exactly at the limit must be accepted")
        XCTAssertEqual(bytes, limit, "Bytes must equal the limit when filled exactly")
    }

    // MARK: - Topic change semantics

    func testNewTopicId_clearsPriorSegmentsFirst() async {
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 0, text: "old0", audioData: Data(repeating: 0, count: 100), topicId: "topicA")
        await cache.cacheSegment(index: 1, text: "old1", audioData: Data(repeating: 0, count: 100), topicId: "topicA")

        // Switching to a different topic must clear first, leaving only the new segment.
        await cache.cacheSegment(index: 7, text: "new", audioData: Data(repeating: 0, count: 50), topicId: "topicB")

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        let oldGone = await cache.getSegment(at: 0)
        let newOnly = await cache.getSegment(at: 7)
        XCTAssertEqual(count, 1, "A new topic must clear prior segments, leaving only the new one")
        XCTAssertEqual(bytes, 50, "Bytes must reset to only the new topic's segment size")
        XCTAssertNil(oldGone, "Prior-topic segments must be cleared on topic change")
        XCTAssertEqual(newOnly?.text, "new", "Only the new topic's segment should remain")
    }

    func testSameTopicId_doesNotClear() async {
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 100), topicId: "topicA")
        await cache.cacheSegment(index: 1, text: "b", audioData: Data(repeating: 0, count: 100), topicId: "topicA")

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        XCTAssertEqual(count, 2, "Caching under the same topic must accumulate, not clear")
        XCTAssertEqual(bytes, 200, "Both same-topic segments must contribute to total bytes (100 + 100)")
        let first = await cache.getSegment(at: 0)
        let second = await cache.getSegment(at: 1)
        XCTAssertEqual(first?.text, "a", "The first same-topic segment must be retained intact")
        XCTAssertEqual(second?.text, "b", "The second same-topic segment must be retained intact")
    }

    func testNilTopicId_doesNotChangeCurrentTopicTracking() async {
        // A nil topicId neither sets nor compares the current topic. After a nil
        // insert the current topic remains "topicA", so a later "topicB" insert
        // still triggers the clear, proving the nil insert did not reset tracking.
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 100), topicId: "topicA")
        await cache.cacheSegment(index: 1, text: "untracked", audioData: Data(repeating: 0, count: 100), topicId: nil)

        let countAfterNil = await cache.segmentCount
        XCTAssertEqual(countAfterNil, 2, "A nil-topic insert must not clear and must just add")

        // The current topic is still topicA, so switching to topicB clears.
        await cache.cacheSegment(index: 2, text: "b", audioData: Data(repeating: 0, count: 50), topicId: "topicB")
        let countAfterSwitch = await cache.segmentCount
        XCTAssertEqual(countAfterSwitch, 1, "Current topic stayed topicA, so topicB must clear prior segments")
    }

    // MARK: - Sorted retrieval

    func testGetAllSegments_returnsSortedByIndexRegardlessOfInsertionOrder() async {
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 5, text: "five", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 1, text: "one", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 3, text: "three", audioData: Data(repeating: 0, count: 10))

        let all = await cache.getAllSegments()
        XCTAssertEqual(all.map(\.index), [1, 3, 5], "getAllSegments must be sorted ascending by index")
    }

    func testGetAllSegments_emptyCacheReturnsEmptyArray() async {
        let cache = AudioSegmentCache()
        let all = await cache.getAllSegments()
        XCTAssertTrue(all.isEmpty, "An empty cache must return an empty array")
    }

    func testGetSegmentsFrom_returnsOnlyIndicesAtOrAboveStartSorted() async {
        let cache = AudioSegmentCache()

        await cache.cacheSegment(index: 4, text: "four", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 1, text: "one", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 2, text: "two", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 6, text: "six", audioData: Data(repeating: 0, count: 10))

        let fromTwo = await cache.getSegments(from: 2)
        XCTAssertEqual(fromTwo.map(\.index), [2, 4, 6], "Must include only index >= 2, sorted ascending")
    }

    func testGetSegmentsFrom_startAboveAllIndicesReturnsEmpty() async {
        let cache = AudioSegmentCache()
        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 1, text: "b", audioData: Data(repeating: 0, count: 10))

        let none = await cache.getSegments(from: 99)
        XCTAssertTrue(none.isEmpty, "A start index above all cached indices must return empty")
    }

    // MARK: - Presence

    func testHasSegment_reflectsPresenceAndAbsence() async {
        let cache = AudioSegmentCache()
        await cache.cacheSegment(index: 2, text: "two", audioData: Data(repeating: 0, count: 10))

        let present = await cache.hasSegment(at: 2)
        let absent = await cache.hasSegment(at: 3)
        XCTAssertTrue(present, "hasSegment must be true for a cached index")
        XCTAssertFalse(absent, "hasSegment must be false for an uncached index")
    }

    // MARK: - cachedRange

    func testCachedRange_isNilWhenEmpty() async {
        let cache = AudioSegmentCache()
        let range = await cache.cachedRange
        XCTAssertNil(range, "cachedRange must be nil when the cache is empty")
    }

    func testCachedRange_isMinThroughMaxRegardlessOfInsertionOrder() async {
        let cache = AudioSegmentCache()

        // Insert out of order to prove min and max are computed, not insertion-based.
        await cache.cacheSegment(index: 8, text: "eight", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 2, text: "two", audioData: Data(repeating: 0, count: 10))
        await cache.cacheSegment(index: 5, text: "five", audioData: Data(repeating: 0, count: 10))

        let range = await cache.cachedRange
        XCTAssertEqual(range, 2...8, "cachedRange must span the minimum through maximum cached index")
    }

    // MARK: - clearCache

    func testClearCache_emptiesCountBytesAndRange() async {
        let cache = AudioSegmentCache()
        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 100), topicId: "topicA")
        await cache.cacheSegment(index: 1, text: "b", audioData: Data(repeating: 0, count: 100), topicId: "topicA")

        await cache.clearCache()

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        let range = await cache.cachedRange
        XCTAssertEqual(count, 0, "clearCache must empty the segment count")
        XCTAssertEqual(bytes, 0, "clearCache must reset total bytes to zero")
        XCTAssertNil(range, "clearCache must reset cachedRange to nil")
    }

    func testClearCache_resetsCurrentTopicSoLaterSameTopicInsertDoesNotClear() async {
        // clearCache resets currentTopicId to nil. A later insert with the same
        // topicId must therefore behave as a fresh start, not trigger a spurious
        // clear of itself.
        let cache = AudioSegmentCache()
        await cache.cacheSegment(index: 0, text: "a", audioData: Data(repeating: 0, count: 100), topicId: "topicA")

        await cache.clearCache()

        // Re-insert under the same topicId, then add another to prove no clear fired.
        await cache.cacheSegment(index: 0, text: "fresh", audioData: Data(repeating: 0, count: 50), topicId: "topicA")
        await cache.cacheSegment(index: 1, text: "more", audioData: Data(repeating: 0, count: 50), topicId: "topicA")

        let count = await cache.segmentCount
        let bytes = await cache.totalCachedBytes
        XCTAssertEqual(count, 2, "After clear, same-topicId inserts must accumulate without a spurious clear")
        XCTAssertEqual(bytes, 100, "Both fresh same-topic segments must be counted (50 + 50)")
    }
}
