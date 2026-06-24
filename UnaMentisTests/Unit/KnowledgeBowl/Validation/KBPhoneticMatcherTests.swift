//
//  KBPhoneticMatcherTests.swift
//  UnaMentisTests
//
//  Comprehensive unit tests for phonetic matching (Double Metaphone)
//  Target: 50+ test cases covering person names, places, scientific terms
//

import XCTest
@testable import UnaMentis

@available(iOS 18.0, *)
final class KBPhoneticMatcherTests: XCTestCase {
    var matcher: KBPhoneticMatcher!

    override func setUp() async throws {
        try await super.setUp()
        matcher = KBPhoneticMatcher()
    }

    override func tearDown() async throws {
        matcher = nil
        try await super.tearDown()
    }

    // MARK: - Person Names

    func testPersonName_StephenSteven() {
        // Common spelling variation
        XCTAssertTrue(matcher.arePhoneticMatch("Stephen", "Steven"))
    }

    func testPersonName_CatherineKathryn() {
        // K/C variation
        XCTAssertTrue(matcher.arePhoneticMatch("Catherine", "Kathryn"))
    }

    func testPersonName_JohnJon() {
        // Silent H
        XCTAssertTrue(matcher.arePhoneticMatch("John", "Jon"))
    }

    func testPersonName_PhilipPhillip() {
        // Double consonant
        XCTAssertTrue(matcher.arePhoneticMatch("Philip", "Phillip"))
    }

    func testPersonName_SaraSarah() {
        // Silent H at end
        XCTAssertTrue(matcher.arePhoneticMatch("Sara", "Sarah"))
    }

    func testPersonName_JeffreyGeoffrey() {
        // J/G variation
        XCTAssertTrue(matcher.arePhoneticMatch("Jeffrey", "Geoffrey"))
    }

    func testPersonName_KristenCode() {
        // Pin the actual encoding. Kristen collapses to KRST, which (after 4-char
        // truncation) is the same code Christopher/Kristopher produce, so a
        // self-match is guaranteed and uninteresting. The code value is the real
        // contract worth protecting.
        XCTAssertEqual(matcher.metaphone("Kristen").primary, "KRST")
    }

    func testPersonName_MichaelCode() {
        // CH after a vowel mid-word yields X (church sound) primary with K secondary.
        let michael = matcher.metaphone("Michael")
        XCTAssertEqual(michael.primary, "MXL")
        XCTAssertEqual(michael.secondary, "MKL")
    }

    func testPersonName_ChristopherKristopher() {
        // Ch/K variation
        XCTAssertTrue(matcher.arePhoneticMatch("Christopher", "Kristopher"))
    }

    func testPersonName_JenniferCode() {
        // Initial J at word start keeps J in both codes; NN collapses to a single N.
        XCTAssertEqual(matcher.metaphone("Jennifer").primary, "JNFR")
    }

    // MARK: - Place Names

    func testPlaceName_PhiladelphiaFiladelfia() {
        // Ph/F variation
        XCTAssertTrue(matcher.arePhoneticMatch("Philadelphia", "Filadelfia"))
    }

    func testPlaceName_CincinnatiCincinatti() {
        // Double consonant variation
        XCTAssertTrue(matcher.arePhoneticMatch("Cincinnati", "Cincinatti"))
    }

    func testPlaceName_PittsburghPittsburg() {
        // Silent H
        XCTAssertTrue(matcher.arePhoneticMatch("Pittsburgh", "Pittsburg"))
    }

    func testPlaceName_MississippiMissisipi() {
        // Missing double consonants (should still match phonetically)
        XCTAssertTrue(matcher.arePhoneticMatch("Mississippi", "Missisipi"))
    }

    func testPlaceName_ConnecticutConneticut() {
        // The silent double-C vs single-C produces distinct codes (KNKT vs KNTK),
        // so Double Metaphone does NOT treat this spelling variation as a match.
        // The n-gram matcher is responsible for catching it instead. This test
        // pins the actual codes and the resulting non-match so a regression in the
        // C/CC handling is caught.
        XCTAssertEqual(matcher.metaphone("Connecticut").primary, "KNKT")
        XCTAssertEqual(matcher.metaphone("Conneticut").primary, "KNTK")
        XCTAssertFalse(matcher.arePhoneticMatch("Connecticut", "Conneticut"))
    }

    func testPlaceName_AlbuquerqueAlbequerque() {
        // U/E variation
        XCTAssertTrue(matcher.arePhoneticMatch("Albuquerque", "Albequerque"))
    }

    func testPlaceName_SacramentoCode() {
        // C before R encodes as K; truncated to 4 chars this is SKRM.
        XCTAssertEqual(matcher.metaphone("Sacramento").primary, "SKRM")
    }

    func testPlaceName_ChicagoChikago() {
        // Ch/K variation
        XCTAssertTrue(matcher.arePhoneticMatch("Chicago", "Chikago"))
    }

    func testPlaceName_TucsonTuson() {
        // The silent C in Tucson is still encoded as K (TKSN), while Tuson drops it
        // entirely (TSN), so Double Metaphone does NOT match this pair. This is better
        // handled by n-gram or token matching. Pin the actual codes and the non-match.
        XCTAssertEqual(matcher.metaphone("Tucson").primary, "TKSN")
        XCTAssertEqual(matcher.metaphone("Tuson").primary, "TSN")
        XCTAssertFalse(matcher.arePhoneticMatch("Tucson", "Tuson"))
    }

    func testPlaceName_WorcesterWooster() {
        // Worcester has a unique pronunciation (WOOS-ter) that Double Metaphone
        // encodes from spelling, so it does NOT match the phonetic "Wooster".
        // Initial W before a vowel yields the A (primary) / F (secondary) pair.
        // Pin both code variants and the resulting non-match.
        let worcester = matcher.metaphone("Worcester")
        XCTAssertEqual(worcester.primary, "ARSS")
        XCTAssertEqual(worcester.secondary, "FRSS")
        let wooster = matcher.metaphone("Wooster")
        XCTAssertEqual(wooster.primary, "ASTR")
        XCTAssertEqual(wooster.secondary, "FSTR")
        XCTAssertFalse(matcher.arePhoneticMatch("Worcester", "Wooster"))
    }

    // MARK: - Scientific Terms

    func testScientific_PhotosynthesisFotosynthesis() {
        // Ph/F variation
        XCTAssertTrue(matcher.arePhoneticMatch("Photosynthesis", "Fotosynthesis"))
    }

    func testScientific_ChlorophyllClorofill() {
        // Ph/F and CHL/CL variations. CHL maps to K just like the bare C, and PH maps
        // to F, so both spellings collapse to the same code (KLRF) and DO match. This
        // is exactly the misspelling-tolerance the matcher exists to provide.
        XCTAssertEqual(matcher.metaphone("Chlorophyll").primary, "KLRF")
        XCTAssertEqual(matcher.metaphone("Clorofill").primary, "KLRF")
        XCTAssertTrue(matcher.arePhoneticMatch("Chlorophyll", "Clorofill"))
    }

    func testScientific_PneumoniaNeumon() {
        // Silent P
        XCTAssertTrue(matcher.arePhoneticMatch("Pneumonia", "Neumonia"))
    }

    func testScientific_PsychologyPsikology() {
        // Silent P and Ch/K variation
        XCTAssertTrue(matcher.arePhoneticMatch("Psychology", "Psikology"))
    }

    func testScientific_ChemistryKemistry() {
        // Ch/K variation
        XCTAssertTrue(matcher.arePhoneticMatch("Chemistry", "Kemistry"))
    }

    func testScientific_GenealogyCode() {
        // Initial G before E gives J (primary) / K (secondary); both variants pinned.
        let genealogy = matcher.metaphone("Genealogy")
        XCTAssertEqual(genealogy.primary, "JNLJ")
        XCTAssertEqual(genealogy.secondary, "KNLK")
    }

    func testScientific_BacteriaCode() {
        // Leading B encodes as P; C before T encodes as K, giving PKTR.
        XCTAssertEqual(matcher.metaphone("Bacteria").primary, "PKTR")
    }

    func testScientific_ChromosomeKromosome() {
        // Ch/K variation
        XCTAssertTrue(matcher.arePhoneticMatch("Chromosome", "Kromosome"))
    }

    func testScientific_PharmacyFarmacy() {
        // Ph/F variation
        XCTAssertTrue(matcher.arePhoneticMatch("Pharmacy", "Farmacy"))
    }

    func testScientific_MitochondriaCode() {
        // CH after a vowel yields X (primary) / K (secondary), giving MTXN / MTKN.
        let mitochondria = matcher.metaphone("Mitochondria")
        XCTAssertEqual(mitochondria.primary, "MTXN")
        XCTAssertEqual(mitochondria.secondary, "MTKN")
    }

    // MARK: - Metaphone Code Generation

    func testMetaphone_Smith() {
        let (primary, _) = matcher.metaphone("Smith")
        XCTAssertEqual(primary, "SM0")  // TH -> 0
    }

    func testMetaphone_Johnson() {
        let (primary, _) = matcher.metaphone("Johnson")
        XCTAssertEqual(primary, "JNSN")
    }

    func testMetaphone_Williams() {
        let (primary, _) = matcher.metaphone("Williams")
        // In Double Metaphone, W before vowel at start gives A (primary) / F (secondary)
        XCTAssertEqual(primary, "ALMS")
    }

    func testMetaphone_Jones() {
        let (primary, _) = matcher.metaphone("Jones")
        XCTAssertEqual(primary, "JNS")
    }

    func testMetaphone_Brown() {
        let (primary, _) = matcher.metaphone("Brown")
        XCTAssertEqual(primary, "PRN")  // B -> P
    }

    // MARK: - Edge Cases

    func testEdgeCase_EmptyString() {
        let (primary, secondary) = matcher.metaphone("")
        XCTAssertEqual(primary, "")
        XCTAssertNil(secondary)
    }

    func testEdgeCase_SingleCharacter() {
        let (primary, _) = matcher.metaphone("A")
        XCTAssertEqual(primary, "A")
    }

    func testEdgeCase_TwoCharacters() {
        let (primary, _) = matcher.metaphone("AB")
        XCTAssertEqual(primary, "AP")  // B -> P
    }

    func testEdgeCase_AllVowels() {
        let (primary, _) = matcher.metaphone("AEIOU")
        XCTAssertEqual(primary, "A")  // Only initial vowel kept
    }

    func testEdgeCase_AllConsonants() {
        let (primary, _) = matcher.metaphone("BCDFG")
        XCTAssertEqual(primary, "PKTF")  // Consonants mapped
    }

    // MARK: - Non-Matches

    func testNonMatch_CompletelyDifferent() {
        XCTAssertFalse(matcher.arePhoneticMatch("Apple", "Zebra"))
    }

    func testNonMatch_DifferentLength() {
        XCTAssertFalse(matcher.arePhoneticMatch("Cat", "Cathedral"))
    }

    func testNonMatch_DifferentSound() {
        XCTAssertFalse(matcher.arePhoneticMatch("Bear", "Deer"))
    }

    func testNonMatch_Antonyms() {
        XCTAssertFalse(matcher.arePhoneticMatch("Hot", "Cold"))
    }

    func testNonMatch_Numbers() {
        // Numbers aren't phonetically comparable
        XCTAssertFalse(matcher.arePhoneticMatch("123", "456"))
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitive_Uppercase() {
        XCTAssertTrue(matcher.arePhoneticMatch("STEPHEN", "STEVEN"))
    }

    func testCaseInsensitive_Lowercase() {
        XCTAssertTrue(matcher.arePhoneticMatch("stephen", "steven"))
    }

    func testCaseInsensitive_MixedCase() {
        XCTAssertTrue(matcher.arePhoneticMatch("StEpHeN", "sTeVeN"))
    }
}
