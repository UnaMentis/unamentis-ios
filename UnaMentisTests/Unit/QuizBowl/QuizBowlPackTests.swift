// UnaMentis - Quiz Bowl Content Pack Tests
// Proves the three bundled Quiz Bowl starter packs load through the host content
// store, decode as [QBItem], meet the required counts and structure (pyramidal
// power marks where the schema calls for them, themed bonus sets for UK), and
// that each pack's manifest is schema-valid with a license and a matching
// integrity hash.
//
// The packs ship as flat bundle resources (<packId>-items.json and
// <packId>-manifest.json). QBContentProvider resolves the items handle and
// decodes through DefaultContentStoreService, so integrity and schema stay the
// store's job.

import CryptoKit
import XCTest
@testable import UnaMentis

final class QuizBowlPackTests: XCTestCase {
    private var content: DefaultContentStoreService!

    override func setUp() {
        super.setUp()
        content = DefaultContentStoreService()
    }

    override func tearDown() {
        content = nil
        super.tearDown()
    }

    // MARK: Load Counts

    func testNAQTPack_loads33ItemsWithPowerMarks() async throws {
        let items = try await QBContentProvider.loadItems(
            packId: "qb-starter-naqt", content: content, bundle: .main
        )
        XCTAssertGreaterThanOrEqual(items.count, 30, "NAQT starter needs 30+ tossups")
        // Every NAQT tossup is pyramidal and carries a power mark (RFC 0005 item 7).
        XCTAssertTrue(items.allSatisfy { $0.powerMarkIndex != nil },
                      "Every NAQT pyramidal tossup must carry a powerMarkIndex")
        let bonuses = items.filter { $0.bonus != nil }
        XCTAssertGreaterThanOrEqual(bonuses.count, 10, "NAQT starter needs 10+ three-part bonuses")
        XCTAssertTrue(bonuses.allSatisfy { $0.bonus?.parts.count == 3 },
                      "Every bonus must have three parts")
    }

    func testIHBBEuropePack_loads30PlusEuropeanItems() async throws {
        let items = try await QBContentProvider.loadItems(
            packId: "ihbb-europe-starter", content: content, bundle: .main
        )
        XCTAssertGreaterThanOrEqual(items.count, 30, "IHBB Europe starter needs 30+ tossups")
        XCTAssertTrue(items.allSatisfy { $0.powerMarkIndex != nil })
        // European emphasis: history and geography dominate.
        let euCore = items.filter { $0.domain == "history" || $0.domain == "geography" }
        XCTAssertGreaterThan(euCore.count, items.count / 2,
                             "IHBB Europe should emphasize history and geography")
    }

    func testUKSchoolsChallengePack_loads20PlusStartersWithThemedBonuses() async throws {
        let items = try await QBContentProvider.loadItems(
            packId: "uk-schools-challenge-starter", content: content, bundle: .main
        )
        XCTAssertGreaterThanOrEqual(items.count, 20, "UK Schools' Challenge needs 20+ starters")
        // Starters are short form: no power marks.
        XCTAssertTrue(items.allSatisfy { $0.powerMarkIndex == nil },
                      "UK starters are short questions without power marks")
        // Themed bonus sets: every starter has a 3-part themed bonus with a lead-in.
        XCTAssertTrue(items.allSatisfy { $0.bonus?.parts.count == 3 },
                      "Every UK starter must have a themed 3-part bonus")
        XCTAssertTrue(items.allSatisfy { ($0.bonus?.leadIn?.isEmpty == false) },
                      "Every UK themed bonus set carries a lead-in theme")
    }

    // MARK: Mapping into the engine

    func testItemsMapOntoEngineQuestions_carryingPowerMarkAndBonus() async throws {
        let items = try await QBContentProvider.loadItems(
            packId: "qb-starter-naqt", content: content, bundle: .main
        )
        let withBonus = try XCTUnwrap(items.first { $0.bonus != nil })
        let question = QBQuestionMapper.engineQuestion(from: withBonus)
        XCTAssertEqual(question.id, withBonus.id)
        XCTAssertEqual(question.powerMarkIndex, withBonus.powerMarkIndex)
        XCTAssertEqual(question.bonus?.parts.count, 3)
        XCTAssertEqual(question.evaluation.primaryAnswer, withBonus.answer.primary)
        XCTAssertEqual(question.evaluation.strictness.id, "qb-standard")
    }

    // MARK: Manifest schema validity and integrity

    func testAllManifests_areSchemaValidWithMatchingIntegrity() throws {
        for packId in ["qb-starter-naqt", "ihbb-europe-starter", "uk-schools-challenge-starter"] {
            let manifestURL = try XCTUnwrap(
                Bundle.main.url(forResource: "\(packId)-manifest", withExtension: "json"),
                "\(packId) manifest must be bundled"
            )
            let itemsURL = try XCTUnwrap(
                Bundle.main.url(forResource: "\(packId)-items", withExtension: "json"),
                "\(packId) items must be bundled"
            )
            let manifest = try JSONDecoder().decode(
                PackManifest.self, from: Data(contentsOf: manifestURL)
            )
            XCTAssertEqual(manifest.packId, packId)
            XCTAssertEqual(manifest.schema, "qb-question/1")
            XCTAssertEqual(manifest.license.spdx, "CC-BY-4.0")
            XCTAssertEqual(manifest.license.attribution, "UnaMentis")
            XCTAssertFalse(manifest.license.spdx.isEmpty)

            // Integrity: the manifest hash matches the item payload.
            let itemsData = try Data(contentsOf: itemsURL)
            let actual = SHA256.hash(data: itemsData)
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, manifest.integrity.sha256.lowercased(),
                           "\(packId) integrity hash must match its items payload")

            // The declared item count matches the decoded payload.
            let items = try JSONDecoder().decode([QBItem].self, from: itemsData)
            XCTAssertEqual(items.count, manifest.itemCount,
                           "\(packId) itemCount must match the payload")
        }
    }

    // MARK: Manifest resolution

    /// The packs ship flat ("<packId>-manifest.json"), so the handle must find
    /// the manifest there and carry its real locale. Probing only the folder
    /// layout meant the manifest was never found and every pack, including the
    /// two en-GB ones, was handed to the store as the en-US default.
    func testBundledHandle_carriesThePackLocaleFromItsManifest() async throws {
        let ihbbHandle = try await QBContentProvider.bundledHandle(
            packId: "ihbb-europe-starter", bundle: .main
        )
        let ihbb = try XCTUnwrap(ihbbHandle)
        XCTAssertEqual(ihbb.locale, "en-GB", "The IHBB Europe starter pack is British English")

        let naqtHandle = try await QBContentProvider.bundledHandle(
            packId: "qb-starter-naqt", bundle: .main
        )
        let naqt = try XCTUnwrap(naqtHandle)
        XCTAssertEqual(naqt.locale, "en-US")
        XCTAssertEqual(naqt.schema, qbQuestionSchema)
    }

    /// A manifest that is present but unreadable is a build defect, and used to
    /// disappear into the same silent locale fallback as "no manifest at all".
    func testBundledHandle_surfacesAnUnreadableManifest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QBPack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("[]".utf8).write(to: directory.appendingPathComponent("broken-pack-items.json"))
        try Data("{ not json at all".utf8)
            .write(to: directory.appendingPathComponent("broken-pack-manifest.json"))
        let bundle = try XCTUnwrap(Bundle(url: directory))

        do {
            _ = try await QBContentProvider.bundledHandle(packId: "broken-pack", bundle: bundle)
            XCTFail("Expected manifestUnreadable")
        } catch let error as QBContentError {
            guard case .manifestUnreadable(let packId, _) = error else {
                return XCTFail("Expected manifestUnreadable, got \(error)")
            }
            XCTAssertEqual(packId, "broken-pack")
        }
    }

    /// A pack that is not in the bundle at all still resolves to nil rather
    /// than throwing, so the caller reports "not bundled".
    func testBundledHandle_absentPackResolvesToNil() async throws {
        let handle = try await QBContentProvider.bundledHandle(
            packId: "no-such-pack", bundle: .main
        )
        XCTAssertNil(handle)
    }

    // MARK: Missing pack

    func testMissingPack_throwsTypedError() async {
        do {
            _ = try await QBContentProvider.loadItems(
                packId: "no-such-pack", content: content, bundle: .main
            )
            XCTFail("Expected packNotBundled")
        } catch let error as QBContentError {
            XCTAssertEqual(error, .packNotBundled("no-such-pack"))
        } catch {
            XCTFail("Expected QBContentError, got \(error)")
        }
    }
}
