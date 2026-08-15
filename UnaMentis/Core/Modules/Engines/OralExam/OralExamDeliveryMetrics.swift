// UnaMentis - Oral Exam Delivery Metrics
// MODULE_SDK_SPEC.md section 6.2: evaluation.deliveryMetrics
// ("pace", "fillerWords", "hesitations").
//
// Delivery metrics come from transcript timing analysis, not the LLM
// (ORAL_EXAM_STUDIO_MODULE_SPEC.md section 4). The analyzer is a pure value
// computation over captured utterance segments so its math is unit-testable
// without any audio: the engine records wall-clock timing around each
// `listen` call and hands the segments here.
//
// Timing model, stated so the numbers mean something:
// - A segment's duration spans listen start to listen return. A segment that
//   ended on the silence threshold therefore INCLUDES that trailing silence,
//   which the analyzer subtracts to approximate actual speaking time.
// - Each silence-ended segment that is followed by another segment in the
//   same monologue is one hesitation gap: the learner went quiet long enough
//   for the endpointer to fire, then resumed. Finer-grained intra-utterance
//   gap timing needs per-word timestamps the pipeline does not surface yet
//   (candidate RFC once STT word timing is exposed).

import Foundation

// MARK: - Metrics

/// Mechanics-of-speaking metrics computed engine-side from transcript timing.
public struct OralExamDeliveryMetrics: Codable, Sendable, Equatable {
    /// Total words across all captured segments.
    public let wordCount: Int

    /// Approximate seconds actually spent speaking (segment durations minus
    /// trailing endpointer silence).
    public let speakingSeconds: Double

    /// Pace: words per minute over `speakingSeconds`. Zero when too little
    /// speech was captured for a meaningful rate.
    public let wordsPerMinute: Double

    /// Occurrences of filler words and phrases ("um", "you know", ...).
    public let fillerWordCount: Int

    /// Hesitation gaps: silences long enough to endpoint an utterance segment
    /// mid-monologue.
    public let hesitationCount: Int

    public init(
        wordCount: Int,
        speakingSeconds: Double,
        wordsPerMinute: Double,
        fillerWordCount: Int,
        hesitationCount: Int
    ) {
        self.wordCount = wordCount
        self.speakingSeconds = speakingSeconds
        self.wordsPerMinute = wordsPerMinute
        self.fillerWordCount = fillerWordCount
        self.hesitationCount = hesitationCount
    }

    /// The all-zero metrics for a session that captured no speech.
    public static let empty = OralExamDeliveryMetrics(
        wordCount: 0,
        speakingSeconds: 0,
        wordsPerMinute: 0,
        fillerWordCount: 0,
        hesitationCount: 0
    )
}

// MARK: - Captured Segment

/// One captured utterance segment with wall-clock timing, as recorded by the
/// engine around a `listen` call.
public struct OralExamCapturedSegment: Sendable, Equatable {
    public let transcript: String

    /// Seconds from an arbitrary shared reference (session start) at which
    /// listening began.
    public let start: TimeInterval

    /// Seconds from the same reference at which the transcript was finalized.
    public let end: TimeInterval

    /// Why the segment ended (silence threshold, max duration, ...).
    public let endedBy: UtteranceResult.EndReason

    public init(
        transcript: String,
        start: TimeInterval,
        end: TimeInterval,
        endedBy: UtteranceResult.EndReason
    ) {
        self.transcript = transcript
        self.start = start
        self.end = end
        self.endedBy = endedBy
    }

    public var duration: TimeInterval { max(0, end - start) }
}

// MARK: - Analyzer

/// Pure delivery-metrics math over captured segments.
public enum OralExamDeliveryAnalyzer {
    /// Single-word fillers, matched per token after lowercasing and stripping
    /// punctuation. English-first (MVP); localized wordlists ride content
    /// packs later.
    public static let fillerWords: Set<String> = [
        "um", "uh", "er", "ah", "erm", "hmm", "like", "basically", "literally", "actually"
    ]

    /// Multi-word fillers, matched as phrases against the normalized token
    /// stream.
    public static let fillerPhrases: [[String]] = [
        ["you", "know"],
        ["i", "mean"],
        ["kind", "of"],
        ["sort", "of"]
    ]

    /// Below this much captured speech, a words-per-minute rate is noise and
    /// reports as zero.
    public static let minimumSpeakingSecondsForPace = 5.0

    /// Count filler-word and filler-phrase occurrences in a transcript.
    /// Phrase matches consume their tokens so "you know" does not also count
    /// a single-word filler.
    public static func fillerCount(in transcript: String) -> Int {
        let tokens = tokenize(transcript)
        var count = 0
        var index = 0
        while index < tokens.count {
            var matchedPhrase = false
            for phrase in fillerPhrases where index + phrase.count <= tokens.count {
                if Array(tokens[index..<(index + phrase.count)]) == phrase {
                    count += 1
                    index += phrase.count
                    matchedPhrase = true
                    break
                }
            }
            if matchedPhrase { continue }
            if fillerWords.contains(tokens[index]) {
                count += 1
            }
            index += 1
        }
        return count
    }

    /// Words-per-minute pace over the given speaking time. Returns zero below
    /// the minimum meaningful duration.
    public static func wordsPerMinute(wordCount: Int, speakingSeconds: Double) -> Double {
        guard speakingSeconds >= minimumSpeakingSecondsForPace, wordCount > 0 else { return 0 }
        return Double(wordCount) / speakingSeconds * 60
    }

    /// Compute delivery metrics from captured segments.
    ///
    /// - Parameters:
    ///   - segments: captured utterance segments in chronological order.
    ///   - silenceThreshold: the endpointing silence threshold the segments
    ///     were captured with; subtracted from silence-ended segment durations
    ///     to approximate speaking time.
    public static func metrics(
        from segments: [OralExamCapturedSegment],
        silenceThreshold: Double
    ) -> OralExamDeliveryMetrics {
        guard !segments.isEmpty else { return .empty }

        var wordCount = 0
        var speakingSeconds = 0.0
        var fillerCount = 0
        var hesitations = 0

        for (index, segment) in segments.enumerated() {
            wordCount += tokenize(segment.transcript).count
            fillerCount += Self.fillerCount(in: segment.transcript)

            let trailingSilence = segment.endedBy == .silence ? silenceThreshold : 0
            speakingSeconds += max(0, segment.duration - trailingSilence)

            // A silence-ended segment followed by more speech is a hesitation
            // gap: the learner paused past the endpointer, then continued.
            if segment.endedBy == .silence, index < segments.count - 1 {
                hesitations += 1
            }
        }

        return OralExamDeliveryMetrics(
            wordCount: wordCount,
            speakingSeconds: speakingSeconds,
            wordsPerMinute: wordsPerMinute(wordCount: wordCount, speakingSeconds: speakingSeconds),
            fillerWordCount: fillerCount,
            hesitationCount: hesitations
        )
    }

    /// Lowercased, punctuation-stripped word tokens.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
