// UnaMentis - Barge-In Classifier
// ================================
//
// The single decision point for "what kind of barge-in is this?"
//
// When the user interrupts the AI (a confirmed barge-in), the transcript is
// either an explicit COMMAND (bookmark, next, repeat, ...) or the user ENGAGING
// the material (a question, a comment, a request for explanation). Those two
// cases route to completely different handling: a command executes locally and
// silently, an engagement opens a conversational turn with the LLM.
//
// Before this type existed the two paths were split and never unified:
// VoiceCommandRecognizer was used only inside Knowledge Bowl, and
// ResponseIntent.classify was used only to pick a filler clip. Nothing decided
// command-vs-engagement for a barge-in. This is that decision, in one place, so
// every narrating surface routes barge-ins the same way and so the decision can
// be measured against a labeled corpus (see BargeInMeasurementHarness).
//
// Policy (v1, deliberately simple so it is measurable then tuned):
//   1. Run the local command recognizer. If it returns a result that meets the
//      execution threshold (confidence >= 0.75), the barge-in is a command.
//   2. Otherwise it is an engagement, sub-typed by ResponseIntent for filler.
// The command vocabulary overlaps engagement language ("again", "go back",
// "wait"), so this baseline will misclassify some cases. That error rate is
// exactly what the measurement quantifies; thresholds and phrases are then tuned
// against real numbers rather than guesses.

import Foundation
import OSLog

// MARK: - Classification Result

/// Coarse category of a barge-in. This is the binary label the measurement
/// harness scores (command vs engagement).
public enum BargeInCategory: String, Sendable, CaseIterable, Codable {
    case command
    case engagement
}

/// The full result of classifying a barge-in transcript.
public enum BargeInClassification: Sendable, Equatable {
    /// An explicit voice command the app should execute locally.
    case command(VoiceCommand, confidence: Float, matchType: VoiceCommandResult.MatchType)
    /// The user engaging the material; route to a conversational turn.
    /// Carries the ResponseIntent used to select an instant filler clip.
    case engagement(ResponseIntent)

    /// The coarse category, for metrics and routing.
    public var category: BargeInCategory {
        switch self {
        case .command: return .command
        case .engagement: return .engagement
        }
    }
}

// MARK: - Barge-In Classifier

/// Classifies a confirmed barge-in transcript as a command or an engagement.
///
/// Holds one ``VoiceCommandRecognizer`` (local, no LLM, no network) and defers
/// to ``ResponseIntent`` for the engagement sub-type. Stateless beyond the
/// recognizer, so it is safe to keep one instance per session and reuse it for
/// every barge-in.
public actor BargeInClassifier {
    private let logger = Logger(subsystem: "com.unamentis", category: "BargeInClassifier")
    private let commandRecognizer: VoiceCommandRecognizer

    /// Minimum command confidence to treat a barge-in as a command rather than
    /// an engagement. Mirrors ``VoiceCommandResult/shouldExecute`` (0.75) but is
    /// exposed so the measurement can sweep it.
    public let commandThreshold: Float

    /// Above this word count, only an exact/whole-word command match is trusted;
    /// fuzzy (phonetic/token) matches are treated as engagement.
    ///
    /// Commands are terse ("next", "bookmark this", "flag for review"). A long
    /// conversational barge-in ("why does that happen?") can phonetically collide
    /// with a command phrase ("what was that"), so the fuzzy tiers, which are
    /// tuned for short command utterances, over-trigger on full sentences. The
    /// shared recognizer is unchanged (Knowledge Bowl depends on it); this
    /// barge-in-specific gate lives here.
    public let fuzzyMatchMaxWords: Int

    public init(
        commandRecognizer: VoiceCommandRecognizer = VoiceCommandRecognizer(),
        commandThreshold: Float = 0.75,
        fuzzyMatchMaxWords: Int = 3
    ) {
        self.commandRecognizer = commandRecognizer
        self.commandThreshold = commandThreshold
        self.fuzzyMatchMaxWords = fuzzyMatchMaxWords
    }

    /// Classify a barge-in transcript.
    /// - Parameters:
    ///   - transcript: The STT transcript of the interrupting utterance.
    ///   - validCommands: Optional context filter restricting which commands are
    ///     valid right now (e.g. a reader allows bookmark/flag but not submit).
    ///     When nil, all commands are eligible.
    /// - Returns: A ``BargeInClassification`` (never throws; an empty or
    ///   unrecognized transcript classifies as engagement).
    public func classify(
        transcript: String,
        validCommands: Set<VoiceCommand>? = nil
    ) async -> BargeInClassification {
        if let match = await commandRecognizer.recognize(
            transcript: transcript,
            validCommands: validCommands
        ), match.confidence >= commandThreshold, isTrustedCommand(match, for: transcript) {
            logger.debug("Barge-in classified as command \(match.command.rawValue) (\(match.confidence))")
            return .command(match.command, confidence: match.confidence, matchType: match.matchType)
        }

        let intent = ResponseIntent.classify(from: transcript)
        logger.debug("Barge-in classified as engagement (\(intent.rawValue))")
        return .engagement(intent)
    }

    /// Whether a recognizer match should be trusted as a command for this
    /// barge-in. Short utterances trust any tier; longer ones require an exact
    /// (whole-word) match so a conversational sentence is not mistaken for a
    /// fuzzy command hit.
    private func isTrustedCommand(_ match: VoiceCommandResult, for transcript: String) -> Bool {
        let wordCount = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .count
        if wordCount <= fuzzyMatchMaxWords { return true }
        return match.matchType == .exact
    }
}
