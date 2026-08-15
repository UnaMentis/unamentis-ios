// UnaMentis - Content Store Service Tests
// MODULE_SDK_SPEC.md section 5.3, capability "content.canonical-question/1".
//
// Real over mock: a real DefaultContentStoreService over a temp imports
// directory. Verifies pack integrity (a bad sha256 rejects the import), that a
// valid pack imports and its items decode, and that a missing license is
// rejected.

import CryptoKit
import XCTest
@testable import UnaMentis

/// A minimal pack item for tests.
private struct TestItem: PackItem, Equatable {
    let id: String
    let value: Int
}

final class ContentStoreServiceTests: XCTestCase {

    private func makeStore() -> (DefaultContentStoreService, URL) {
        let imports = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (DefaultContentStoreService(bundle: .main, importsRoot: imports), imports)
    }

    private func removeRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write a pack directory (manifest.json + items.json) and return its URL.
    /// If `corruptHash` is true, the manifest carries a hash that does not match
    /// the items payload.
    private func writePack(
        packId: String,
        items: [TestItem],
        spdx: String = "CC-BY-4.0",
        attribution: String = "Test Author",
        corruptHash: Bool = false,
        schema: String = "canonical-question/1"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let itemsData = try encoder.encode(items)
        try itemsData.write(to: dir.appendingPathComponent("items.json"))

        let realHash = SHA256.hash(data: itemsData).map { String(format: "%02x", $0) }.joined()
        let hash = corruptHash ? String(repeating: "0", count: 64) : realHash

        let manifest = PackManifest(
            packId: packId,
            name: "Test Pack",
            version: "1.0.0",
            schema: schema,
            locale: "en-US",
            license: PackManifest.License(spdx: spdx, attribution: attribution),
            integrity: PackManifest.Integrity(sha256: hash),
            itemCount: items.count
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    // MARK: - Integrity

    func testImport_rejectsIntegrityMismatch() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let packURL = try writePack(packId: "bad-pack", items: [TestItem(id: "a", value: 1)], corruptHash: true)
        defer { try? FileManager.default.removeItem(at: packURL) }

        do {
            _ = try await store.importPack(from: packURL)
            XCTFail("Import should have failed integrity check")
        } catch let error as ContentStoreError {
            guard case .integrityMismatch = error else {
                return XCTFail("Expected integrityMismatch, got \(error)")
            }
        }
    }

    func testImport_acceptsValidPackAndDecodesItems() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let items = [TestItem(id: "a", value: 1), TestItem(id: "b", value: 2)]
        let packURL = try writePack(packId: "good-pack", items: items)
        defer { try? FileManager.default.removeItem(at: packURL) }

        let handle = try await store.importPack(from: packURL)
        XCTAssertEqual(handle.packId, "good-pack")
        XCTAssertEqual(handle.origin, .imported)

        let decoded = try await store.items(TestItem.self, from: handle, query: .all)
        XCTAssertEqual(decoded, items)
    }

    func testImport_rejectsMissingLicense() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let packURL = try writePack(
            packId: "no-license", items: [TestItem(id: "a", value: 1)], spdx: "", attribution: ""
        )
        defer { try? FileManager.default.removeItem(at: packURL) }

        do {
            _ = try await store.importPack(from: packURL)
            XCTFail("Import should have rejected a pack without a license")
        } catch let error as ContentStoreError {
            guard case .licenseMissing = error else {
                return XCTFail("Expected licenseMissing, got \(error)")
            }
        }
    }

    func testItemQuery_limitCapsResults() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let items = (0..<10).map { TestItem(id: "\($0)", value: $0) }
        let packURL = try writePack(packId: "big-pack", items: items)
        defer { try? FileManager.default.removeItem(at: packURL) }

        let handle = try await store.importPack(from: packURL)
        let decoded = try await store.items(TestItem.self, from: handle, query: ItemQuery(limit: 3))
        XCTAssertEqual(decoded.count, 3)
    }

    func testItemQuery_nonPositiveLimitReturnsNothingInsteadOfTrapping() async throws {
        // Array.prefix(-1) traps, so a negative limit used to crash the app.
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let items = (0..<3).map { TestItem(id: "\($0)", value: $0) }
        let packURL = try writePack(packId: "limit-pack", items: items)
        defer { try? FileManager.default.removeItem(at: packURL) }

        let handle = try await store.importPack(from: packURL)
        let negative = try await store.items(TestItem.self, from: handle, query: ItemQuery(limit: -1))
        XCTAssertTrue(negative.isEmpty)
        let zero = try await store.items(TestItem.self, from: handle, query: ItemQuery(limit: 0))
        XCTAssertTrue(zero.isEmpty)
    }

    // MARK: - Load-time integrity

    func testItems_rejectsAPackCorruptedAfterImport() async throws {
        // Integrity was only checked at import, so a pack modified afterwards
        // (sync, partial write, tampering) loaded silently, contradicting the
        // store's own contract.
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let packURL = try writePack(packId: "tampered", items: [TestItem(id: "a", value: 1)])
        defer { try? FileManager.default.removeItem(at: packURL) }
        let handle = try await store.importPack(from: packURL)

        // The pack loads while it is intact.
        let before = try await store.items(TestItem.self, from: handle, query: .all)
        XCTAssertEqual(before.count, 1)

        // Rewrite the stored items behind the store's back.
        let storedItems = try XCTUnwrap(handle.itemsURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode([TestItem(id: "evil", value: 99)]).write(to: storedItems)

        do {
            _ = try await store.items(TestItem.self, from: handle, query: .all)
            XCTFail("A corrupted pack must not load")
        } catch let error as ContentStoreError {
            guard case .integrityMismatch = error else {
                return XCTFail("Expected integrityMismatch, got \(error)")
            }
        }
    }

    // MARK: - Schema compatibility

    func testImport_rejectsUnsupportedSchema() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        for schema in ["canonical-question/2", "canonical-question", "", "canonical-question/x"] {
            let packURL = try writePack(
                packId: "schema-\(abs(schema.hashValue))",
                items: [TestItem(id: "a", value: 1)],
                schema: schema
            )
            defer { try? FileManager.default.removeItem(at: packURL) }
            do {
                _ = try await store.importPack(from: packURL)
                XCTFail("Schema '\(schema)' must not import")
            } catch let error as ContentStoreError {
                guard case .schemaUnsupported = error else {
                    return XCTFail("Expected schemaUnsupported for '\(schema)', got \(error)")
                }
            }
        }
    }

    func testSchemaSupport_acceptsEveryShippingPackSchema() {
        for schema in [
            "canonical-question/1", "qb-question/1", "drill-items/1",
            "aural-items/1", "oral-syllabus/1"
        ] {
            XCTAssertTrue(
                DefaultContentStoreService.isSchemaSupported(schema),
                "\(schema) is a shipping pack schema and must load"
            )
        }
        XCTAssertFalse(DefaultContentStoreService.isSchemaSupported("qb-question/2"))
    }

    // MARK: - Bundled KB pack

    func testPacks_includesBundledKBPack() async {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let packs = await store.packs(matching: .all)
        XCTAssertTrue(
            packs.contains { $0.packId == "kb-sample-questions" && $0.origin == .bundled },
            "The bundled KB sample pack should be discoverable"
        )
    }

    func testItems_decodesBundledKBQuestions() async throws {
        let (store, root) = makeStore()
        defer { removeRoot(root) }

        let packs = await store.packs(matching: PackQuery(schema: "canonical-question/1"))
        guard let kb = packs.first(where: { $0.packId == "kb-sample-questions" }) else {
            return XCTFail("Bundled KB pack not found")
        }
        let questions = try await store.items(KBQuestion.self, from: kb, query: ItemQuery(limit: 5))
        XCTAssertEqual(questions.count, 5)
    }
}
