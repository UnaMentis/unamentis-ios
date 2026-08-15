// UnaMentis - Quiz Bowl Session Planner
// Decides WHICH of a pack's items one practice session runs, and in what order.
//
// Two rules, both descriptor-driven data rather than code:
//   - the format descriptor's `oral.questions` is the session's default length,
//     so a session runs the number of tossups the competition declares (NAQT 24,
//     ACF 20, IHBB Europe 24, UK Schools' Challenge 20) rather than the whole
//     pack, which is deliberately larger than one session;
//   - selection is shuffled, so repeat practice on the same pack is a different
//     session rather than the same items in the same order every time.
//
// The randomness is injectable. Tests pass a seed and get a stable, repeatable
// selection; production uses the system generator.
//
// Writing style: no em dashes (see .claude/rules/writing-style.md).

import Foundation

enum QBSessionPlanner {
    /// Select the items for one session: shuffle, then take `questionCount`.
    ///
    /// A nil or non-positive `questionCount` means "no declared length", which
    /// runs the whole (shuffled) pack. A pack smaller than the declared count
    /// runs in full rather than repeating items.
    static func selectItems<G: RandomNumberGenerator>(
        from items: [QBItem],
        questionCount: Int?,
        using generator: inout G
    ) -> [QBItem] {
        let shuffled = items.shuffled(using: &generator)
        guard let questionCount, questionCount > 0 else { return shuffled }
        return Array(shuffled.prefix(questionCount))
    }

    /// Select the items for one session, seeding the shuffle when a seed is
    /// given (tests) and using the system generator otherwise (production).
    static func selectItems(
        from items: [QBItem],
        questionCount: Int?,
        seed: UInt64? = nil
    ) -> [QBItem] {
        if let seed {
            var generator = QBSeededGenerator(seed: seed)
            return selectItems(from: items, questionCount: questionCount, using: &generator)
        }
        var generator = SystemRandomNumberGenerator()
        return selectItems(from: items, questionCount: questionCount, using: &generator)
    }

    /// Select the items for one session from a format descriptor, honoring its
    /// declared oral question count.
    static func selectItems(
        from items: [QBItem],
        descriptor: QuizMatchFormatDescriptor,
        seed: UInt64? = nil
    ) -> [QBItem] {
        selectItems(from: items, questionCount: descriptor.oral?.questions, seed: seed)
    }
}

// MARK: - Deterministic Generator

/// A reproducible `RandomNumberGenerator` (SplitMix64) so a seeded session
/// selection is identical run to run.
///
/// `SystemRandomNumberGenerator` is deliberately unseedable, so tests that need
/// a stable shuffle need their own generator. SplitMix64 is small, has no
/// dependencies, and is well distributed enough for shuffling a question pack.
struct QBSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
