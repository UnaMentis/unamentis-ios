//
//  KBRegionalConfigTests.swift
//  UnaMentisTests
//
//  Tests for KBRegionalConfig and KBRegion regional rule configurations
//

import XCTest
@testable import UnaMentis

final class KBRegionalConfigTests: XCTestCase {

    // MARK: - KBRegion Tests

    func testRegion_allCases_containsAllRegions() {
        let allCases = KBRegion.allCases

        XCTAssertTrue(allCases.contains(.colorado))
        XCTAssertTrue(allCases.contains(.coloradoSprings))
        XCTAssertTrue(allCases.contains(.minnesota))
        XCTAssertTrue(allCases.contains(.washington))
        XCTAssertEqual(allCases.count, 4)
    }

    func testRegion_displayName_returnsHumanReadableName() {
        XCTAssertEqual(KBRegion.colorado.displayName, "Colorado")
        XCTAssertEqual(KBRegion.coloradoSprings.displayName, "Colorado Springs")
        XCTAssertEqual(KBRegion.minnesota.displayName, "Minnesota")
        XCTAssertEqual(KBRegion.washington.displayName, "Washington")
    }

    func testRegion_abbreviation_returnsStateCode() {
        XCTAssertEqual(KBRegion.colorado.abbreviation, "CO")
        XCTAssertEqual(KBRegion.coloradoSprings.abbreviation, "CO")
        XCTAssertEqual(KBRegion.minnesota.abbreviation, "MN")
        XCTAssertEqual(KBRegion.washington.abbreviation, "WA")
    }

    func testRegion_id_returnsStableRawValueString() {
        // The Identifiable id is the stable string used for SwiftUI list identity
        // and persistence. Assert the concrete values, not a tautology against
        // rawValue, so a renamed case is caught here.
        XCTAssertEqual(KBRegion.colorado.id, "colorado")
        XCTAssertEqual(KBRegion.coloradoSprings.id, "coloradoSprings")
        XCTAssertEqual(KBRegion.minnesota.id, "minnesota")
        XCTAssertEqual(KBRegion.washington.id, "washington")
    }

    func testRegion_config_returnsCorrectConfiguration() {
        let coloradoConfig = KBRegion.colorado.config
        XCTAssertEqual(coloradoConfig.region, .colorado)

        let minnesotaConfig = KBRegion.minnesota.config
        XCTAssertEqual(minnesotaConfig.region, .minnesota)
    }

    func testRegion_codable_usesRawValueWireFormat() throws {
        // KBRegion is persisted (session configs, saved practice). The on-disk
        // wire format must stay the rawValue string so old saves keep decoding.
        // A round-trip alone only re-tests synthesized Codable; assert the
        // concrete encoded bytes so a custom CodingKeys change is caught.
        let region = KBRegion.coloradoSprings

        let data = try JSONEncoder().encode(region)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertEqual(json, "\"coloradoSprings\"")

        let decoded = try JSONDecoder().decode(KBRegion.self, from: data)
        XCTAssertEqual(decoded, region)

        // Decoding from a hand-written legacy string must still work.
        let legacy = Data("\"minnesota\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(KBRegion.self, from: legacy), .minnesota)
    }

    // MARK: - Colorado Configuration Tests

    func testColoradoConfig_teamConfiguration() {
        let config = KBRegionalConfig.forRegion(.colorado)

        XCTAssertEqual(config.teamsPerMatch, 3)
        XCTAssertEqual(config.minTeamSize, 1)
        XCTAssertEqual(config.maxTeamSize, 4)
        XCTAssertEqual(config.activePlayersInOral, 4)
    }

    func testColoradoConfig_writtenRound() {
        let config = KBRegionalConfig.forRegion(.colorado)

        XCTAssertEqual(config.writtenQuestionCount, 60)
        XCTAssertEqual(config.writtenTimeLimit, 900)  // 15 minutes
        XCTAssertEqual(config.writtenPointsPerCorrect, 1)
    }

    func testColoradoConfig_oralRound() {
        let config = KBRegionalConfig.forRegion(.colorado)

        XCTAssertEqual(config.oralQuestionCount, 50)
        XCTAssertEqual(config.oralPointsPerCorrect, 5)
        XCTAssertTrue(config.reboundEnabled)
    }

    func testColoradoConfig_conferenceRules() {
        let config = KBRegionalConfig.forRegion(.colorado)

        XCTAssertEqual(config.conferenceTime, 15)
        XCTAssertFalse(config.verbalConferringAllowed)  // CRITICAL: Colorado prohibits verbal
        XCTAssertTrue(config.handSignalsAllowed)
    }

    func testColoradoConfig_scoringRules() {
        let config = KBRegionalConfig.forRegion(.colorado)

        XCTAssertFalse(config.negativeScoring)
        XCTAssertFalse(config.sosBonus)
    }

    // MARK: - Minnesota Configuration Tests

    func testMinnesotaConfig_teamConfiguration() {
        let config = KBRegionalConfig.forRegion(.minnesota)

        XCTAssertEqual(config.teamsPerMatch, 3)
        XCTAssertEqual(config.minTeamSize, 3)  // Different from Colorado
        XCTAssertEqual(config.maxTeamSize, 6)  // Different from Colorado
        XCTAssertEqual(config.activePlayersInOral, 4)
    }

    func testMinnesotaConfig_writtenRound() {
        let config = KBRegionalConfig.forRegion(.minnesota)

        XCTAssertEqual(config.writtenQuestionCount, 60)
        XCTAssertEqual(config.writtenTimeLimit, 900)
        XCTAssertEqual(config.writtenPointsPerCorrect, 2)  // 2 points, not 1
    }

    func testMinnesotaConfig_conferenceRules() {
        let config = KBRegionalConfig.forRegion(.minnesota)

        XCTAssertEqual(config.conferenceTime, 15)
        XCTAssertTrue(config.verbalConferringAllowed)  // Minnesota allows verbal
        XCTAssertTrue(config.handSignalsAllowed)
    }

    func testMinnesotaConfig_scoringRules() {
        let config = KBRegionalConfig.forRegion(.minnesota)

        XCTAssertFalse(config.negativeScoring)
        XCTAssertTrue(config.sosBonus)  // Minnesota has SOS bonus
    }

    // MARK: - Washington Configuration Tests

    func testWashingtonConfig_teamConfiguration() {
        let config = KBRegionalConfig.forRegion(.washington)

        XCTAssertEqual(config.teamsPerMatch, 3)
        XCTAssertEqual(config.minTeamSize, 3)
        XCTAssertEqual(config.maxTeamSize, 5)  // Different from others
    }

    func testWashingtonConfig_writtenRound() {
        let config = KBRegionalConfig.forRegion(.washington)

        XCTAssertEqual(config.writtenQuestionCount, 50)  // Only 50 questions
        XCTAssertEqual(config.writtenTimeLimit, 2700)  // 45 minutes (much longer)
        XCTAssertEqual(config.writtenPointsPerCorrect, 2)
    }

    func testWashingtonConfig_conferenceRules() {
        let config = KBRegionalConfig.forRegion(.washington)

        XCTAssertTrue(config.verbalConferringAllowed)
        XCTAssertTrue(config.handSignalsAllowed)
    }

    // MARK: - Colorado Springs Configuration Tests

    func testColoradoSpringsConfig_matchesColoradoBase() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        let coloradoSprings = KBRegionalConfig.forRegion(.coloradoSprings)

        // Should match most settings
        XCTAssertEqual(coloradoSprings.teamsPerMatch, colorado.teamsPerMatch)
        XCTAssertEqual(coloradoSprings.writtenQuestionCount, colorado.writtenQuestionCount)
        XCTAssertEqual(coloradoSprings.oralPointsPerCorrect, colorado.oralPointsPerCorrect)
        XCTAssertEqual(coloradoSprings.verbalConferringAllowed, colorado.verbalConferringAllowed)
    }

    // MARK: - Display Formatting Tests

    func testWrittenPointsDisplay_singularAndPlural() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        XCTAssertEqual(colorado.writtenPointsDisplay, "1 pt")

        let minnesota = KBRegionalConfig.forRegion(.minnesota)
        XCTAssertEqual(minnesota.writtenPointsDisplay, "2 pts")
    }

    func testOralPointsDisplay_formatsCorrectly() {
        let config = KBRegionalConfig.forRegion(.colorado)
        XCTAssertEqual(config.oralPointsDisplay, "5 pts")
    }

    func testWrittenTimeLimitDisplay_formatsAsMinutes() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        XCTAssertEqual(colorado.writtenTimeLimitDisplay, "15 min")

        let washington = KBRegionalConfig.forRegion(.washington)
        XCTAssertEqual(washington.writtenTimeLimitDisplay, "45 min")
    }

    func testConferenceTimeDisplay_formatsAsSeconds() {
        let config = KBRegionalConfig.forRegion(.colorado)
        XCTAssertEqual(config.conferenceTimeDisplay, "15 sec")
    }

    func testConferringRuleDescription_returnsCorrectDescription() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        XCTAssertEqual(colorado.conferringRuleDescription, "Hand signals only (no verbal)")

        let minnesota = KBRegionalConfig.forRegion(.minnesota)
        XCTAssertEqual(minnesota.conferringRuleDescription, "Verbal discussion allowed")
    }

    // MARK: - Default Configuration Tests

    func testDefault_returnsColoradoConfig() {
        let defaultConfig = KBRegionalConfig.default
        let colorado = KBRegionalConfig.forRegion(.colorado)

        XCTAssertEqual(defaultConfig.region, colorado.region)
        XCTAssertEqual(defaultConfig.writtenQuestionCount, colorado.writtenQuestionCount)
        XCTAssertEqual(defaultConfig.oralPointsPerCorrect, colorado.oralPointsPerCorrect)
    }

    // MARK: - Key Differences Tests

    func testKeyDifferences_coloradoVsMinnesota_identifiesConferring() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        let minnesota = KBRegionalConfig.forRegion(.minnesota)

        let differences = colorado.keyDifferences(from: minnesota)

        // Assert the exact phrasing produced, since these strings drive the
        // user-facing rule comparison table. Loose substring checks would pass
        // even if the wording or the self/other ordering regressed.
        XCTAssertTrue(differences.contains("Conferring: no verbal vs verbal allowed"))
        XCTAssertTrue(differences.contains("Written points: 1 vs 2 per question"))
        XCTAssertTrue(differences.contains("SOS: no SOS vs has SOS bonus"))

        // Colorado and Minnesota share question count and written time, so
        // those lines must NOT appear.
        XCTAssertFalse(differences.contains { $0.hasPrefix("Written:") })
        XCTAssertFalse(differences.contains { $0.hasPrefix("Written time:") })
    }

    func testKeyDifferences_coloradoVsWashington_identifiesTimeAndCount() {
        let colorado = KBRegionalConfig.forRegion(.colorado)
        let washington = KBRegionalConfig.forRegion(.washington)

        let differences = colorado.keyDifferences(from: washington)

        // Colorado: 60 questions / 15 min written. Washington: 50 / 45 min.
        // Assert the exact comparison strings the rule table renders.
        XCTAssertTrue(differences.contains("Written: 60 vs 50 questions"))
        XCTAssertTrue(differences.contains("Written time: 15 min vs 45 min"))
    }

    func testKeyDifferences_sameRegion_returnsEmpty() {
        let colorado = KBRegionalConfig.forRegion(.colorado)

        let differences = colorado.keyDifferences(from: colorado)

        XCTAssertTrue(differences.isEmpty)
    }

    // MARK: - Equatable Tests

    func testEquatable_isSensitiveToASingleFieldChange() throws {
        // The synthesized Equatable must compare every stored field. Colorado vs
        // Minnesota differ in many fields, which would still pass even if some
        // fields were excluded from the comparison. To prove field sensitivity,
        // round-trip Colorado, flip exactly one field via JSON, and require the
        // result to be unequal to the original.
        let colorado = KBRegionalConfig.forRegion(.colorado)
        XCTAssertFalse(colorado.verbalConferringAllowed)

        var dict = try jsonObject(from: colorado)
        dict["verbalConferringAllowed"] = true
        let mutated = try decodeConfig(from: dict)

        XCTAssertNotEqual(
            colorado,
            mutated,
            "Equatable must detect a change in verbalConferringAllowed"
        )
        XCTAssertTrue(mutated.verbalConferringAllowed)
        // Every other field must be untouched, so the description should now
        // read as a verbal-allowed region despite being built from Colorado.
        XCTAssertEqual(mutated.conferringRuleDescription, "Verbal discussion allowed")
    }

    // MARK: - JSON Mutation Helpers

    private func jsonObject(from config: KBRegionalConfig) throws -> [String: Any] {
        let data = try JSONEncoder().encode(config)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func decodeConfig(from dict: [String: Any]) throws -> KBRegionalConfig {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(KBRegionalConfig.self, from: data)
    }

    // MARK: - Codable Tests

    func testCodable_encodesAndDecodes() throws {
        let config = KBRegionalConfig.forRegion(.minnesota)

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KBRegionalConfig.self, from: data)

        XCTAssertEqual(decoded.region, config.region)
        XCTAssertEqual(decoded.writtenQuestionCount, config.writtenQuestionCount)
        XCTAssertEqual(decoded.verbalConferringAllowed, config.verbalConferringAllowed)
        XCTAssertEqual(decoded.sosBonus, config.sosBonus)
    }

    // MARK: - KBSessionConfig Tests

    func testSessionConfig_writtenPractice_usesRegionDefaults() {
        let config = KBSessionConfig.writtenPractice(region: .colorado)

        XCTAssertEqual(config.region, .colorado)
        XCTAssertEqual(config.roundType, .written)
        XCTAssertEqual(config.questionCount, 60)  // Colorado default
        XCTAssertEqual(config.timeLimit, 900)  // 15 minutes
    }

    func testSessionConfig_writtenPractice_allowsCustomization() {
        let config = KBSessionConfig.writtenPractice(
            region: .colorado,
            questionCount: 20,
            timeLimit: 300,
            domains: [.science, .mathematics],
            difficulty: .varsity
        )

        XCTAssertEqual(config.questionCount, 20)
        XCTAssertEqual(config.timeLimit, 300)
        XCTAssertEqual(config.domains, [.science, .mathematics])
        XCTAssertEqual(config.difficulty, .varsity)
    }

    func testSessionConfig_oralPractice_usesRegionDefaults() {
        let config = KBSessionConfig.oralPractice(region: .minnesota)

        XCTAssertEqual(config.region, .minnesota)
        XCTAssertEqual(config.roundType, .oral)
        XCTAssertEqual(config.questionCount, 50)
        XCTAssertNil(config.timeLimit)  // Oral rounds have no time limit
    }

    func testSessionConfig_quickPractice_usesCustomCount() {
        let config = KBSessionConfig.quickPractice(region: .washington, roundType: .written, questionCount: 10)

        XCTAssertEqual(config.questionCount, 10)
        XCTAssertEqual(config.roundType, .written)
        // Time limit should be proportional: 10 questions * 15 seconds
        XCTAssertEqual(config.timeLimit, 150)
    }

    func testSessionConfig_quickPractice_oralHasNoTimeLimit() {
        let config = KBSessionConfig.quickPractice(region: .colorado, roundType: .oral, questionCount: 10)

        XCTAssertEqual(config.roundType, .oral)
        XCTAssertNil(config.timeLimit)
    }

    func testSessionConfig_codable_encodesAndDecodes() throws {
        let config = KBSessionConfig.writtenPractice(
            region: .minnesota,
            questionCount: 30,
            domains: [.science]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KBSessionConfig.self, from: data)

        XCTAssertEqual(decoded.region, config.region)
        XCTAssertEqual(decoded.roundType, config.roundType)
        XCTAssertEqual(decoded.questionCount, config.questionCount)
        XCTAssertEqual(decoded.domains, config.domains)
    }

    // MARK: - Rule Validation Tests (Important for Competition Accuracy)

    func testColorado_verbalConferringProhibited() {
        // CRITICAL: Colorado explicitly prohibits verbal conferring
        let config = KBRegionalConfig.forRegion(.colorado)
        XCTAssertFalse(
            config.verbalConferringAllowed,
            "Colorado rules prohibit verbal conferring. This is a critical competition rule."
        )
    }

    func testMinnesota_hasSOSBonus() {
        // Minnesota has Speed of Sound (SOS) bonus for quick answers
        let config = KBRegionalConfig.forRegion(.minnesota)
        XCTAssertTrue(
            config.sosBonus,
            "Minnesota rules include SOS bonus. This is a distinguishing feature."
        )
    }

    func testWashington_longerWrittenTime() {
        // Washington has significantly longer written round
        let washington = KBRegionalConfig.forRegion(.washington)
        let colorado = KBRegionalConfig.forRegion(.colorado)

        XCTAssertGreaterThan(
            washington.writtenTimeLimit,
            colorado.writtenTimeLimit * 2,
            "Washington written round should be significantly longer than Colorado's."
        )
    }

    func testAllRegions_haveRebound() {
        // All regions support rebound (answering after opponent misses)
        for region in KBRegion.allCases {
            let config = KBRegionalConfig.forRegion(region)
            XCTAssertTrue(config.reboundEnabled, "\(region.displayName) should have rebound enabled")
        }
    }

    func testAllRegions_haveNoNegativeScoring() {
        // No regions use negative scoring
        for region in KBRegion.allCases {
            let config = KBRegionalConfig.forRegion(region)
            XCTAssertFalse(config.negativeScoring, "\(region.displayName) should not have negative scoring")
        }
    }
}
