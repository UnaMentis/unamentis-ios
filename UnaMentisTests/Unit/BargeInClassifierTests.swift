// UnaMentis - Barge-In Classifier Tests
// Verifies the single command-vs-engagement decision point.

import XCTest
@testable import UnaMentis

final class BargeInClassifierTests: XCTestCase {

    var classifier: BargeInClassifier!

    override func setUp() async throws {
        classifier = BargeInClassifier()
    }

    override func tearDown() async throws {
        classifier = nil
    }

    // MARK: - Commands

    func testExplicitCommandsClassifyAsCommand() async {
        let cases: [(String, VoiceCommand)] = [
            ("bookmark this", .bookmark),
            ("flag this for review", .flag),
            ("next", .next),
            ("skip", .skip),
            ("repeat", .repeatLast)
        ]
        for (transcript, expected) in cases {
            let result = await classifier.classify(transcript: transcript)
            XCTAssertEqual(result.category, .command, "\(transcript) should be a command")
            if case let .command(command, confidence, _) = result {
                XCTAssertEqual(command, expected, "\(transcript) -> \(command.rawValue)")
                XCTAssertGreaterThanOrEqual(confidence, 0.75)
            } else {
                XCTFail("\(transcript) did not classify as a command")
            }
        }
    }

    // MARK: - Engagement

    func testQuestionsClassifyAsEngagement() async {
        let questions = [
            "why is the sky blue?",
            "what is photosynthesis",
            "how do plants make energy",
            "tell me more about the Renaissance"
        ]
        for transcript in questions {
            let result = await classifier.classify(transcript: transcript)
            XCTAssertEqual(result.category, .engagement, "\(transcript) should be engagement")
        }
    }

    func testEngagementCarriesResponseIntent() async {
        let result = await classifier.classify(transcript: "why does that happen?")
        guard case let .engagement(intent) = result else {
            return XCTFail("expected engagement, got \(result)")
        }
        XCTAssertEqual(intent, .engagement)
    }

    func testEmptyTranscriptIsEngagementNotCrash() async {
        let result = await classifier.classify(transcript: "")
        XCTAssertEqual(result.category, .engagement)
    }

    // MARK: - Length gate (fuzzy matches only trusted for short utterances)

    func testLongExactCommandIsStillCommand() async {
        // 4 words, but "flag this" is an exact whole-word match, so it stays a command.
        let result = await classifier.classify(transcript: "flag this for review")
        XCTAssertEqual(result.category, .command)
    }

    func testLongFuzzyMatchIsEngagementNotCommand() async {
        // "why does that happen?" phonetically collides with the repeat command,
        // but a 4-word question is the user engaging, not issuing a command.
        let result = await classifier.classify(transcript: "why does that happen?")
        XCTAssertEqual(result.category, .engagement)
    }

    // MARK: - Context filtering

    func testValidCommandsFilterExcludesOutOfContextCommands() async {
        // In a reader, only bookmark/flag are valid. "next" must not be treated
        // as a command and should fall through to engagement.
        let result = await classifier.classify(
            transcript: "next",
            validCommands: [.bookmark, .flag]
        )
        XCTAssertEqual(result.category, .engagement, "next is not a valid reader command")
    }

    func testValidCommandsFilterAllowsInContextCommand() async {
        let result = await classifier.classify(
            transcript: "bookmark this",
            validCommands: [.bookmark, .flag]
        )
        XCTAssertEqual(result.category, .command)
    }

    // MARK: - Threshold is configurable

    func testCommandThresholdIsExposed() async {
        let strict = BargeInClassifier(commandThreshold: 0.95)
        let threshold = await strict.commandThreshold
        XCTAssertEqual(threshold, 0.95)
    }
}
