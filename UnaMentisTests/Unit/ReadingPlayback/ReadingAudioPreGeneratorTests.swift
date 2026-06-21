// UnaMentis - ReadingAudioPreGenerator + ReadingTTSCache Tests
// Unit tests for the deterministic, non-synthesizing public surface of the
// reading audio pre-generator and the reading TTS cache wrapper.
//
// TESTING PHILOSOPHY (Real Over Mock):
// - Real PersistenceController(inMemory: true), real Core Data entities.
// - These tests deliberately do NOT trigger synthesis. The pre-generator
//   resolves its TTS provider internally via TTSProvider.resolveConfiguredService()
//   (on-device Pocket TTS by default), which needs a downloaded model and is not
//   injectable, so the actual synthesis loop is not unit-testable here. Coverage
//   focuses on the guards, progress bookkeeping, configuration, and the empty
//   short-circuit, none of which perform synthesis.

import XCTest
import CoreData
@testable import UnaMentis

final class ReadingAudioPreGeneratorTests: XCTestCase {

    private let preGenCountKey = "reading_preGenChunkCount"
    private var savedPreGenCount: Any?

    override func setUp() {
        super.setUp()
        // Preserve any developer-configured override so we can restore it.
        savedPreGenCount = UserDefaults.standard.object(forKey: preGenCountKey)
        UserDefaults.standard.removeObject(forKey: preGenCountKey)
    }

    override func tearDown() {
        if let saved = savedPreGenCount {
            UserDefaults.standard.set(saved, forKey: preGenCountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preGenCountKey)
        }
        savedPreGenCount = nil
        super.tearDown()
    }

    // MARK: - defaultPreGenCount

    func testDefaultPreGenCount_whenUnset_returnsTwenty() {
        UserDefaults.standard.removeObject(forKey: preGenCountKey)
        XCTAssertEqual(ReadingAudioPreGenerator.defaultPreGenCount, 20)
    }

    func testDefaultPreGenCount_whenSetPositive_returnsOverride() {
        UserDefaults.standard.set(7, forKey: preGenCountKey)
        XCTAssertEqual(ReadingAudioPreGenerator.defaultPreGenCount, 7)
    }

    func testDefaultPreGenCount_whenSetZero_fallsBackToDefault() {
        // The implementation treats a stored 0 (or negative) as "unset".
        UserDefaults.standard.set(0, forKey: preGenCountKey)
        XCTAssertEqual(ReadingAudioPreGenerator.defaultPreGenCount, 20)
    }

    func testDefaultPreGenCount_whenSetNegative_fallsBackToDefault() {
        UserDefaults.standard.set(-5, forKey: preGenCountKey)
        XCTAssertEqual(ReadingAudioPreGenerator.defaultPreGenCount, 20)
    }

    // MARK: - PreGenChunkSpec

    func testPreGenChunkSpec_storesFields() {
        let spec = PreGenChunkSpec(index: 3, text: "Some chunk text")
        XCTAssertEqual(spec.index, 3)
        XCTAssertEqual(spec.text, "Some chunk text")
    }

    // MARK: - Progress / isGenerating for unknown items

    func testGetProgress_unknownItem_returnsNil() async {
        let unknownId = UUID()
        let progress = await ReadingAudioPreGenerator.shared.getProgress(itemId: unknownId)
        XCTAssertNil(progress, "No progress should exist for an item never generated")
    }

    func testIsGenerating_unknownItem_returnsFalse() async {
        let unknownId = UUID()
        let generating = await ReadingAudioPreGenerator.shared.isGenerating(itemId: unknownId)
        XCTAssertFalse(generating)
    }

    func testWaitForPreGeneration_unknownItem_returnsNilImmediately() async {
        let unknownId = UUID()
        let result = await ReadingAudioPreGenerator.shared.waitForPreGeneration(itemId: unknownId)
        XCTAssertNil(result, "Waiting on a non-existent generation returns nil immediately")
    }

    // MARK: - Empty short-circuit (does not register a task, no synthesis)

    func testPreGenerateChunks_withEmptyChunks_doesNotStartGeneration() async {
        let persistence = PersistenceController(inMemory: true)
        let itemId = UUID()

        await ReadingAudioPreGenerator.shared.preGenerateChunks(
            itemId: itemId,
            chunks: [],
            persistenceController: persistence
        )

        // Empty chunks short-circuit before any task is registered.
        let generating = await ReadingAudioPreGenerator.shared.isGenerating(itemId: itemId)
        XCTAssertFalse(generating, "Empty chunk list should not start a generation task")

        let progress = await ReadingAudioPreGenerator.shared.getProgress(itemId: itemId)
        XCTAssertNil(progress, "Empty chunk list should not create progress state")
    }
}

// MARK: - ReadingTTSCache

final class ReadingTTSCacheTests: XCTestCase {

    func testShared_isSingleton() {
        let first = ReadingTTSCache.shared
        let second = ReadingTTSCache.shared
        XCTAssertTrue(first === second, "ReadingTTSCache.shared must return the same instance")
    }

    func testGetService_returnsUsableTTSService() async {
        // ReadingTTSCache delegates to AudioTTSCache, which resolves the configured
        // provider (Pocket TTS by default). We only assert that a real conforming
        // service instance is returned and answers a basic protocol query, not that
        // it can synthesize (that needs a downloaded model).
        let service = await ReadingTTSCache.shared.getService()
        let cost = await service.costPerCharacter
        XCTAssertGreaterThanOrEqual(cost, 0, "A real TTS service exposes a non-negative cost")
    }
}
