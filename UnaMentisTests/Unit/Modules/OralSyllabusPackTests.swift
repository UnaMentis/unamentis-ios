// UnaMentis - Oral Syllabus Content Pack Tests
//
// Verifies the bundled oral-syllabus/1 starter pack (MODULE_SDK_SPEC.md
// section 7): the manifest and items load, license and integrity are present
// and valid, the pack carries the promised topic count and structure, and the
// English-topic filter excludes the French example topics the pipeline cannot
// run yet (RFC 0002 item 6).

import XCTest
@testable import UnaMentis

final class OralSyllabusPackTests: XCTestCase {

    func testBundledPack_loadsWithValidLicenseAndIntegrity() throws {
        let (manifest, items) = try OralSyllabusPack.loadBundled()

        XCTAssertEqual(manifest.packId, OralSyllabusPack.packId)
        XCTAssertEqual(manifest.schema, "oral-syllabus/1")
        XCTAssertEqual(manifest.license.spdx, "CC-BY-4.0")
        XCTAssertEqual(manifest.license.attribution, "UnaMentis")
        XCTAssertFalse(manifest.integrity.sha256.isEmpty)
        XCTAssertEqual(manifest.itemCount, items.count)
    }

    func testBundledPack_hasTenPlusEnglishTopicsAcrossDomains() throws {
        let (_, items) = try OralSyllabusPack.loadBundled()
        let english = OralSyllabusPack.sessionReadyItems(from: items)
        XCTAssertGreaterThanOrEqual(english.count, 10, "MVP needs 10+ English topics")

        // Spanning sciences and humanities.
        let domains = Set(english.map(\.domain))
        XCTAssertTrue(domains.contains("science"))
        XCTAssertTrue(
            domains.contains("history") || domains.contains("literature")
                || domains.contains("philosophy") || domains.contains("linguistics"),
            "English topics must span humanities as well as sciences"
        )
    }

    func testBundledPack_everyTopicHasSixPlusJuryQuestions() throws {
        let (_, items) = try OralSyllabusPack.loadBundled()
        for item in items {
            XCTAssertGreaterThanOrEqual(
                item.juryQuestions.count, 6,
                "Topic '\(item.title)' must ship 6+ exemplar jury questions"
            )
            XCTAssertFalse(item.summary.isEmpty, "Topic '\(item.title)' needs a seed summary")
        }
    }

    func testBundledPack_includesTwoFrenchExampleTopics() throws {
        let (_, items) = try OralSyllabusPack.loadBundled()
        let french = items.filter { $0.locale.lowercased().hasPrefix("fr") }
        XCTAssertEqual(french.count, 2)
        // French topics are content only; the English-ready filter excludes them.
        let englishIds = Set(OralSyllabusPack.sessionReadyItems(from: items).map(\.id))
        XCTAssertTrue(french.allSatisfy { !englishIds.contains($0.id) })
    }

    func testTopic_mapsToEngineTopic() throws {
        let (_, items) = try OralSyllabusPack.loadBundled()
        let item = try XCTUnwrap(items.first)
        let topic = item.engineTopic
        XCTAssertEqual(topic.id, item.id)
        XCTAssertEqual(topic.title, item.title)
        XCTAssertEqual(topic.exemplarQuestions, item.juryQuestions)
        XCTAssertEqual(topic.domain, item.domain)
    }
}
