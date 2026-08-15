// UnaMentis - SAT Prep Content Tests
// Pack-loading coverage: item counts, schema/manifest validity, integrity,
// license, skill-tag coverage against the SAT_MODULE.md taxonomy, the per-item
// evaluation-spec choice (numeric vs text-fuzzy vs conventions), and the loader's
// refusal behavior on malformed content (missing vs unreadable descriptors,
// duplicate item ids).

import XCTest
@testable import UnaMentis

final class SATPrepContentTests: XCTestCase {

    // MARK: - Temp bundle helper

    /// A directory-backed `Bundle` holding hand-written resources, so the
    /// loader's real resource lookup, integrity check, and decode run against
    /// deliberately malformed packs. No mocks: this is the production loader on
    /// a different bundle.
    private var tempBundleRoots: [URL] = []

    override func tearDown() {
        for root in tempBundleRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempBundleRoots = []
        super.tearDown()
    }

    private func makeTempBundle(files: [String: Data]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SATPrepContentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempBundleRoots.append(root)
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
        }
        guard let bundle = Bundle(url: root) else {
            throw XCTSkip("Could not build a directory bundle at \(root.path)")
        }
        return bundle
    }

    /// A manifest whose integrity hash matches `itemsData`, so a test reaches the
    /// decode step instead of stopping at the integrity gate.
    private func manifestJSON(packId: String, itemsData: Data, itemCount: Int) throws -> Data {
        let manifest = PackManifest(
            packId: packId,
            name: packId,
            version: "1.0.0",
            schema: "drill-items/1",
            locale: "en-US",
            license: PackManifest.License(spdx: "CC-BY-4.0", attribution: "UnaMentis"),
            integrity: PackManifest.Integrity(sha256: SATPrepPackLoader.sha256Hex(itemsData)),
            itemCount: itemCount
        )
        return try JSONEncoder().encode(manifest)
    }

    // MARK: - Counts

    func testVocabPack_hasAtLeast40Items() throws {
        let items = try SATPrepPackLoader.items(for: .vocab)
        XCTAssertGreaterThanOrEqual(items.count, 40, "The vocab pack must ship 40+ items.")
    }

    func testMathPack_hasAtLeast30Items() throws {
        let items = try SATPrepPackLoader.items(for: .math)
        XCTAssertGreaterThanOrEqual(items.count, 30, "The math pack must ship 30+ items.")
    }

    func testPackManifests_countsMatchItemFiles() throws {
        for kind in SATDrillKind.allCases {
            let manifest = try SATPrepPackLoader.manifest(for: kind)
            let items = try SATPrepPackLoader.items(for: kind)
            XCTAssertEqual(manifest.itemCount, items.count,
                           "\(kind.packName) manifest itemCount must match the items file.")
        }
    }

    // MARK: - Manifest validity

    func testPackManifests_declareLicenseAndSchema() throws {
        for kind in SATDrillKind.allCases {
            let manifest = try SATPrepPackLoader.manifest(for: kind)
            XCTAssertEqual(manifest.schema, "drill-items/1")
            XCTAssertEqual(manifest.license.spdx, "CC-BY-4.0")
            XCTAssertEqual(manifest.license.attribution, "UnaMentis")
            XCTAssertEqual(manifest.locale, "en-US")
            XCTAssertFalse(manifest.integrity.sha256.isEmpty)
        }
    }

    // MARK: - Integrity

    func testPacks_passIntegrityCheck() throws {
        // items(for:) integrity-checks the payload against the manifest hash and
        // throws on mismatch; loading without throwing is the assertion.
        XCTAssertNoThrow(try SATPrepPackLoader.items(for: .vocab))
        XCTAssertNoThrow(try SATPrepPackLoader.items(for: .math))
    }

    // MARK: - Item validity

    func testItems_haveNonEmptyPromptAnswerAndSkillTag() throws {
        for kind in SATDrillKind.allCases {
            let items = try SATPrepPackLoader.items(for: kind)
            for item in items {
                XCTAssertFalse(item.prompt.isEmpty, "\(item.id) has an empty prompt.")
                XCTAssertFalse(item.answer.isEmpty, "\(item.id) has an empty answer.")
                XCTAssertFalse(item.skillTag.isEmpty, "\(item.id) has an empty skill tag.")
                XCTAssertFalse(item.domain.isEmpty, "\(item.id) has an empty domain.")
            }
        }
    }

    func testItemIds_areUniqueWithinAndAcrossPacks() throws {
        let vocab = try SATPrepPackLoader.items(for: .vocab).map(\.id)
        let math = try SATPrepPackLoader.items(for: .math).map(\.id)
        XCTAssertEqual(Set(vocab).count, vocab.count, "Vocab item ids must be unique.")
        XCTAssertEqual(Set(math).count, math.count, "Math item ids must be unique.")
        XCTAssertTrue(Set(vocab).isDisjoint(with: Set(math)), "Item ids must not collide across packs.")
    }

    // MARK: - Skill tag / domain coverage (SAT_MODULE.md taxonomy)

    func testVocabPack_coversReadingWritingDomains() throws {
        let items = try SATPrepPackLoader.items(for: .vocab)
        let domains = Set(items.map(\.domain))
        // SAT Reading/Writing domains (SAT_MODULE.md).
        XCTAssertTrue(domains.contains("craft-and-structure"))
        XCTAssertTrue(domains.contains("expression-of-ideas"))
        // A voice-friendly vocab pack leans on words-in-context and transitions.
        let skills = Set(items.map(\.skillTag))
        XCTAssertTrue(skills.contains("words-in-context"))
        XCTAssertTrue(skills.contains("transitions"))
    }

    func testMathPack_coversMathDomains() throws {
        let items = try SATPrepPackLoader.items(for: .math)
        let domains = Set(items.map(\.domain))
        // SAT Math domains (SAT_MODULE.md).
        XCTAssertTrue(domains.contains("algebra"))
        XCTAssertTrue(domains.contains("problem-solving-data"))
        XCTAssertTrue(domains.isSuperset(of: ["algebra", "problem-solving-data"]))
    }

    // MARK: - Evaluation spec choice

    func testMathItems_areNumericAndBuildNumericSpecs() throws {
        let items = try SATPrepPackLoader.items(for: .math)
        for item in items {
            XCTAssertTrue(item.isNumeric, "\(item.id) math answer should be numeric.")
            let spec = item.evaluationSpec()
            XCTAssertEqual(spec.category, .numeric)
            XCTAssertTrue(spec.evaluatorTiers.contains(.numeric))
        }
    }

    func testVocabItems_buildTextFuzzySpecs() throws {
        let items = try SATPrepPackLoader.items(for: .vocab)
        // Most vocab answers are words; the spec is text-fuzzy.
        for item in items {
            let spec = item.evaluationSpec()
            if !item.isNumeric {
                XCTAssertEqual(spec.category, .text)
                XCTAssertTrue(spec.evaluatorTiers.contains(.textFuzzy))
            }
        }
    }

    // MARK: - Conventions items (form choice, not meaning)

    func testConventionsItems_useTheStrictProfile() throws {
        let items = try SATPrepPackLoader.items(for: .vocab)
        let conventions = items.filter { $0.domain == "standard-english-conventions" }
        XCTAssertFalse(conventions.isEmpty, "The vocab pack must carry conventions items.")
        for item in conventions {
            let spec = item.evaluationSpec()
            XCTAssertEqual(spec.strictness.level, .strict,
                           "\(item.id) is a form choice: the enhanced fuzzy tiers must be off.")
            XCTAssertEqual(spec.strictness.id, "sat-conventions")
        }
        // Meaning-based items keep the full fuzzy stack.
        for item in items where item.domain != "standard-english-conventions" {
            XCTAssertEqual(item.evaluationSpec().strictness.level, .standard,
                           "\(item.id) is judged on meaning and needs the synonym tiers.")
        }
    }

    /// Every conventions answer the pack itself declares correct must evaluate
    /// correct: the strict profile tightens the tiers, it does not reject the
    /// items' own answers.
    func testConventionsItems_acceptTheirOwnAnswers() async throws {
        let evaluator = DefaultResponseEvaluationService()
        let items = try SATPrepPackLoader.items(for: .vocab)
            .filter { $0.domain == "standard-english-conventions" }
        for item in items {
            let spec = item.evaluationSpec()
            for answer in [item.answer] + (item.acceptable ?? []) {
                let result = await evaluator.evaluate(LearnerResponse(text: answer), against: spec)
                XCTAssertEqual(result.verdict, .correct,
                               "\(item.id) should accept its own answer '\(answer)'.")
            }
        }
    }

    /// The two replacement items (voc-040, voc-041) are scorable by voice: the
    /// expected spoken answers pass, and the answer each prompt explicitly poses
    /// as the alternative is rejected.
    ///
    /// This is the ruling the conventions profile exists for. Judged at the
    /// standard tier, Double Metaphone encodes "there" and "they are" identically
    /// (0R), so the homophone the item is teaching against would score correct.
    func testReplacedConventionsItems_scoreTheIntendedDistinction() async throws {
        let evaluator = DefaultResponseEvaluationService()
        let items = try SATPrepPackLoader.items(for: .vocab)
        guard let contraction = items.first(where: { $0.id == "voc-040" }),
              let possessive = items.first(where: { $0.id == "voc-041" }) else {
            return XCTFail("Expected voc-040 and voc-041 in the vocab pack.")
        }

        // voc-040 is a two-way run-on judgement. It replaced an expand-the-
        // contraction item that speech recognition could not score: a spoken
        // "they are" is routinely transcribed back as "they're", so a correct
        // expansion and a bare repetition of the contraction were
        // indistinguishable.
        let boundarySpec = contraction.evaluationSpec()
        for accepted in ["run-on", "run on"] {
            let result = await evaluator.evaluate(LearnerResponse(text: accepted), against: boundarySpec)
            XCTAssertEqual(result.verdict, .correct, "voc-040 should accept '\(accepted)'.")
        }
        for rejected in ["correct", "one sentence"] {
            let result = await evaluator.evaluate(LearnerResponse(text: rejected), against: boundarySpec)
            XCTAssertEqual(result.verdict, .incorrect,
                           "voc-040 must reject the wrong judgement '\(rejected)'.")
        }

        let possessiveSpec = possessive.evaluationSpec()
        for accepted in ["possession", "possessive", "it's possessive"] {
            let result = await evaluator.evaluate(LearnerResponse(text: accepted), against: possessiveSpec)
            XCTAssertEqual(result.verdict, .correct, "voc-041 should accept '\(accepted)'.")
        }
        let wrong = await evaluator.evaluate(LearnerResponse(text: "contraction"), against: possessiveSpec)
        XCTAssertEqual(wrong.verdict, .incorrect, "voc-041 must reject 'contraction'.")
    }

    /// Lemmatization maps "is" and "are" (and "has" and "have") onto the same
    /// lemma, so the standard tier would mark the wrong verb correct.
    func testConventionsVerbItems_rejectTheSharedLemmaDistractor() async throws {
        let evaluator = DefaultResponseEvaluationService()
        let items = try SATPrepPackLoader.items(for: .vocab)
        let pairs: [(id: String, wrong: String)] = [("voc-042", "are"), ("voc-043", "have")]
        for pair in pairs {
            guard let item = items.first(where: { $0.id == pair.id }) else {
                XCTFail("Expected \(pair.id) in the vocab pack.")
                continue
            }
            let result = await evaluator.evaluate(
                LearnerResponse(text: pair.wrong), against: item.evaluationSpec()
            )
            XCTAssertEqual(result.verdict, .incorrect,
                           "\(pair.id) must reject '\(pair.wrong)': it shares a lemma with the answer.")
        }
    }

    // MARK: - Malformed content refusal

    /// A pack with a duplicate item id is REFUSED with a typed error. The
    /// previous by-id map (`Dictionary(uniqueKeysWithValues:)`) trapped on this,
    /// so the same content took the app down instead of surfacing a failure.
    func testItems_refuseDuplicateItemIdsWithoutTrapping() throws {
        let itemsData = Data("""
            [
              {"id": "voc-001", "skillTag": "words-in-context", "domain": "craft-and-structure",
               "prompt": "First prompt.", "answer": "alpha"},
              {"id": "voc-001", "skillTag": "words-in-context", "domain": "craft-and-structure",
               "prompt": "Second prompt with the same id.", "answer": "beta"},
              {"id": "voc-002", "skillTag": "transitions", "domain": "expression-of-ideas",
               "prompt": "Third prompt.", "answer": "gamma"}
            ]
            """.utf8)
        let bundle = try makeTempBundle(files: [
            "sat-vocab-context-items.json": itemsData,
            "sat-vocab-context-manifest.json": try manifestJSON(
                packId: "sat-vocab-context", itemsData: itemsData, itemCount: 3
            )
        ])

        XCTAssertThrowsError(try SATPrepPackLoader.items(for: .vocab, bundle: bundle)) { error in
            guard case SATPrepPackLoader.LoadError.duplicateItemIds(let name, let ids) = error else {
                return XCTFail("Expected duplicateItemIds, got \(error)")
            }
            XCTAssertEqual(name, "sat-vocab-context")
            XCTAssertEqual(ids, ["voc-001"])
        }
    }

    func testDecodeItems_reportsUnreadablePayloadWithTheUnderlyingReason() {
        let malformed = Data("[{\"id\": \"voc-001\"}]".utf8)
        XCTAssertThrowsError(try SATPrepPackLoader.decodeItems(malformed, packName: "sat-vocab-context")) { error in
            guard case SATPrepPackLoader.LoadError.itemsUnreadable(let name, let reason) = error else {
                return XCTFail("Expected itemsUnreadable, got \(error)")
            }
            XCTAssertEqual(name, "sat-vocab-context")
            XCTAssertFalse(reason.isEmpty, "The underlying decode failure must be preserved.")
        }
    }

    /// A descriptor that is PRESENT but malformed must not be reported as
    /// missing: the two failures point at different fixes, and the text reaches
    /// the learner.
    func testDescriptor_malformedReportsUnreadableNotMissing() throws {
        let bundle = try makeTempBundle(files: [
            "sat-vocab-drill.json": Data("{ \"formatId\": ".utf8)
        ])
        XCTAssertThrowsError(try SATPrepPackLoader.descriptor(for: .vocab, bundle: bundle)) { error in
            guard case SATPrepPackLoader.LoadError.descriptorUnreadable(let name, let reason) = error else {
                return XCTFail("Expected descriptorUnreadable, got \(error)")
            }
            XCTAssertEqual(name, "sat-vocab-drill")
            XCTAssertFalse(reason.isEmpty, "The underlying decode failure must be preserved.")
            let described = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(described.contains("missing"),
                           "A malformed descriptor must not be described as missing.")
            XCTAssertEqual((error as? LocalizedError)?.failureReason, reason)
        }
    }

    func testDescriptor_absentResourceStillReportsMissing() throws {
        let bundle = try makeTempBundle(files: [:])
        XCTAssertThrowsError(try SATPrepPackLoader.descriptor(for: .vocab, bundle: bundle)) { error in
            guard case SATPrepPackLoader.LoadError.descriptorMissing(let name) = error else {
                return XCTFail("Expected descriptorMissing, got \(error)")
            }
            XCTAssertEqual(name, "sat-vocab-drill")
        }
    }

    // MARK: - Live evaluation through the host service

    func testMathAnswer_evaluatesCorrectAndRejectsNearMiss() async throws {
        let items = try SATPrepPackLoader.items(for: .math)
        guard let five = items.first(where: { $0.answer == "5" }) else {
            return XCTFail("Expected a math item with answer 5.")
        }
        let evaluator = DefaultResponseEvaluationService()
        let hit = await evaluator.evaluate(LearnerResponse(text: "5"), against: five.evaluationSpec())
        XCTAssertEqual(hit.verdict, .correct)
        let miss = await evaluator.evaluate(LearnerResponse(text: "6"), against: five.evaluationSpec())
        XCTAssertEqual(miss.verdict, .incorrect)
    }
}
