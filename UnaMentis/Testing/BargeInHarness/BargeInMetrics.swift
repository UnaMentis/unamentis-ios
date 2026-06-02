// UnaMentis - Barge-In Metrics
// ============================
//
// Pure aggregation of per-clip measurement outcomes into the goal criteria
// (see .claude/goals/barge-in.json):
//   - barge-in reaction latency (median, p95)
//   - STT time-to-first-partial (median)
//   - detection recall
//   - noise/echo false-positive rate
//   - command-vs-engagement macro F1
//
// This file is intentionally free of audio, actors, and I/O so the math is
// deterministic and unit-testable with known inputs. The harness produces
// `[BargeInClipOutcome]`; `BargeInMetrics.compute` turns them into numbers.
//
// Latency percentiles reuse the app's `[TimeInterval].median` / `.percentile`
// (nearest-rank) so measurement numbers match the rest of the app's reporting.

import Foundation

/// The true nature of a corpus clip.
public enum BargeInClipType: String, Sendable, Codable, CaseIterable {
    /// An explicit voice command spoken as a barge-in (should detect + classify command).
    case command
    /// The user engaging the material (should detect + classify engagement).
    case engagement
    /// Background noise; no barge-in should be detected.
    case noise
    /// The app's own TTS played back (echo/self-trigger); no barge-in should be detected.
    case echo

    /// The expected classifier category for positives, nil for negatives.
    public var expectedClass: BargeInCategory? {
        switch self {
        case .command: return .command
        case .engagement: return .engagement
        case .noise, .echo: return nil
        }
    }

    /// Whether a barge-in should be detected for this clip type.
    public var expectDetect: Bool {
        switch self {
        case .command, .engagement: return true
        case .noise, .echo: return false
        }
    }
}

/// The measured outcome for a single corpus clip.
public struct BargeInClipOutcome: Sendable, Codable, Equatable {
    public let clipId: String
    public let type: BargeInClipType
    /// Whether a barge-in was confirmed.
    public let detected: Bool
    /// Speech onset to confirmed barge-in, ms. Nil if not detected.
    public let reactionMs: Double?
    /// Speech onset to first STT partial, ms. Nil if no partial was produced.
    public let firstPartialMs: Double?
    /// Classifier output for a detected barge-in. Nil if undetected or no transcript.
    public let predictedClass: BargeInCategory?
    /// The transcript STT produced (for debugging), if any.
    public let transcript: String?

    public init(
        clipId: String,
        type: BargeInClipType,
        detected: Bool,
        reactionMs: Double? = nil,
        firstPartialMs: Double? = nil,
        predictedClass: BargeInCategory? = nil,
        transcript: String? = nil
    ) {
        self.clipId = clipId
        self.type = type
        self.detected = detected
        self.reactionMs = reactionMs
        self.firstPartialMs = firstPartialMs
        self.predictedClass = predictedClass
        self.transcript = transcript
    }

    public var expectedClass: BargeInCategory? { type.expectedClass }
    public var expectDetect: Bool { type.expectDetect }
}

/// Aggregated metrics across a measurement run.
public struct BargeInMetrics: Sendable, Codable, Equatable {
    public let reactionMsMedian: Double?
    public let reactionMsP95: Double?
    public let sttFirstPartialMsMedian: Double?
    public let detectionRecall: Double?
    public let falsePositiveRate: Double?
    public let commandVsEngagementMacroF1: Double?

    // Sample counts, always reported so a green run on too few samples is visible.
    public let positiveSamples: Int      // clips where a barge-in should be detected
    public let negativeSamples: Int      // noise/echo clips
    public let detectedCount: Int        // positives detected
    public let falsePositiveCount: Int   // negatives wrongly detected
    public let classifiedSamples: Int    // detected positives with a prediction (basis for F1)
    public let firstPartialSamples: Int  // detected positives with an STT first-partial (basis for STT latency)

    /// Aggregate per-clip outcomes into the goal criteria. Pure; no I/O.
    public static func compute(from outcomes: [BargeInClipOutcome]) -> BargeInMetrics {
        let positives = outcomes.filter { $0.expectDetect }
        let negatives = outcomes.filter { !$0.expectDetect }

        // Detection recall over positives.
        let detected = positives.filter { $0.detected }
        let recall: Double? = positives.isEmpty ? nil : Double(detected.count) / Double(positives.count)

        // False-positive rate over negatives.
        let falsePositives = negatives.filter { $0.detected }
        let fpr: Double? = negatives.isEmpty ? nil : Double(falsePositives.count) / Double(negatives.count)

        // Latencies over detected positives.
        let reactions: [TimeInterval] = detected.compactMap { $0.reactionMs }
        let reactionMedian: Double? = reactions.isEmpty ? nil : reactions.median
        let reactionP95: Double? = reactions.isEmpty ? nil : reactions.percentile(95)

        // STT first-partial latency over detected positives only (symmetric with
        // reaction latency); a wrongly-detected negative must not skew it.
        let firstPartials: [TimeInterval] = detected.compactMap { $0.firstPartialMs }
        let firstPartialMedian: Double? = firstPartials.isEmpty ? nil : firstPartials.median

        // Command-vs-engagement macro F1 over detected+classified positives.
        let classified = positives.filter { $0.expectedClass != nil && $0.predictedClass != nil }
        let macroF1: Double? = classified.isEmpty
            ? nil
            : macroF1Score(classified.map { (expected: $0.expectedClass!, predicted: $0.predictedClass!) })

        return BargeInMetrics(
            reactionMsMedian: reactionMedian,
            reactionMsP95: reactionP95,
            sttFirstPartialMsMedian: firstPartialMedian,
            detectionRecall: recall,
            falsePositiveRate: fpr,
            commandVsEngagementMacroF1: macroF1,
            positiveSamples: positives.count,
            negativeSamples: negatives.count,
            detectedCount: detected.count,
            falsePositiveCount: falsePositives.count,
            classifiedSamples: classified.count,
            firstPartialSamples: firstPartials.count
        )
    }

    /// Macro F1 over the two classes (command, engagement).
    private static func macroF1Score(_ pairs: [(expected: BargeInCategory, predicted: BargeInCategory)]) -> Double {
        let classes: [BargeInCategory] = [.command, .engagement]
        var f1s: [Double] = []
        for c in classes {
            let tp = pairs.filter { $0.expected == c && $0.predicted == c }.count
            let fp = pairs.filter { $0.expected != c && $0.predicted == c }.count
            let fn = pairs.filter { $0.expected == c && $0.predicted != c }.count
            let precision = (tp + fp) == 0 ? 0.0 : Double(tp) / Double(tp + fp)
            let recall = (tp + fn) == 0 ? 0.0 : Double(tp) / Double(tp + fn)
            let f1 = (precision + recall) == 0 ? 0.0 : 2 * precision * recall / (precision + recall)
            f1s.append(f1)
        }
        return f1s.reduce(0, +) / Double(f1s.count)
    }
}
