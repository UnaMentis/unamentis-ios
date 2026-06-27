// UnaMentis - Barge-In Tuning ("nerd knobs")
//
// Runtime-adjustable barge-in parameters, persisted in UserDefaults so they can
// be experimented with ON DEVICE, in real rooms, with real voices and real
// background noise, WITHOUT a rebuild. The goal is to dial in what will become
// near-permanent defaults. The barge-in STATE MACHINE (BargeInDetector) is fixed
// and unit-tested; these knobs only move the thresholds it runs against.
//
// Surfaced in Settings -> Barge-In Tuning. Keep this to a few high-leverage knobs.

import Foundation

public enum BargeInTuning {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let enabled = "bargeIn.enabled"
        static let confidence = "bargeIn.confidenceThreshold"
        static let sustainedMs = "bargeIn.sustainedSpeechMs"
        static let resumeSec = "bargeIn.resumeAfterNoEngagementSec"
    }

    /// Current best-guess defaults (the values shipped before any tuning).
    public static let defaultEnabled = true
    public static let defaultConfidence: Float = 0.7
    public static let defaultSustainedMs = 700
    public static let defaultResumeSec: Double = 6.0

    // Allowed ranges for the tuning UI sliders.
    public static let confidenceRange: ClosedRange<Float> = 0.3...0.95
    public static let sustainedMsRange: ClosedRange<Double> = 200...2000
    public static let resumeSecRange: ClosedRange<Double> = 2...15

    /// Master enable for barge-in.
    public static var enabled: Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? defaultEnabled
    }

    /// VAD confidence a frame must exceed to count as speech. Higher = less
    /// sensitive (ignores quieter / less speech-like noise).
    public static var confidenceThreshold: Float {
        (defaults.object(forKey: Key.confidence) as? Float).map { min(max($0, confidenceRange.lowerBound), confidenceRange.upperBound) }
            ?? defaultConfidence
    }

    /// How long speech must SUSTAIN before it interrupts narration. Higher =
    /// harder to interrupt, more immune to background noise and echo.
    public static var sustainedSpeechMs: Int {
        let v = defaults.object(forKey: Key.sustainedMs) as? Int ?? defaultSustainedMs
        return Int(min(max(Double(v), sustainedMsRange.lowerBound), sustainedMsRange.upperBound))
    }

    /// After a confirmed barge-in, if the user produces no real utterance within
    /// this many seconds, narration auto-resumes so it is never stuck.
    public static var resumeAfterNoEngagementSec: Double {
        let v = defaults.object(forKey: Key.resumeSec) as? Double ?? defaultResumeSec
        return min(max(v, resumeSecRange.lowerBound), resumeSecRange.upperBound)
    }

    /// Build the detector config from the current knob values.
    public static func detectorConfig() -> BargeInDetectorConfig {
        BargeInDetectorConfig(
            enabled: enabled,
            confidenceThreshold: confidenceThreshold,
            sustainedSpeechMs: sustainedSpeechMs
        )
    }

    // MARK: - Setters (used by the tuning UI)

    public static func setEnabled(_ value: Bool) { defaults.set(value, forKey: Key.enabled) }
    public static func setConfidenceThreshold(_ value: Float) { defaults.set(value, forKey: Key.confidence) }
    public static func setSustainedSpeechMs(_ value: Int) { defaults.set(value, forKey: Key.sustainedMs) }
    public static func setResumeAfterNoEngagementSec(_ value: Double) { defaults.set(value, forKey: Key.resumeSec) }

    /// Reset all knobs to defaults.
    public static func resetToDefaults() {
        defaults.removeObject(forKey: Key.enabled)
        defaults.removeObject(forKey: Key.confidence)
        defaults.removeObject(forKey: Key.sustainedMs)
        defaults.removeObject(forKey: Key.resumeSec)
    }
}
