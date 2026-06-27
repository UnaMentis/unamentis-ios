// UnaMentis - Barge-In Tuning ("nerd knobs")
//
// On-device, runtime-adjustable barge-in parameters. The point is to load a good
// build and dial these in across real rooms, voices, and background noise without
// rebuilding, then lock in the winning values as defaults. Backed by BargeInTuning
// (UserDefaults). Changes apply to the next session.

import SwiftUI

struct BargeInTuningView: View {

    @State private var enabled = BargeInTuning.enabled
    @State private var confidence = Double(BargeInTuning.confidenceThreshold)
    @State private var sustainedMs = Double(BargeInTuning.sustainedSpeechMs)
    @State private var resumeSec = BargeInTuning.resumeAfterNoEngagementSec

    var body: some View {
        List {
            Section {
                Toggle("Barge-In Enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, value in BargeInTuning.setEnabled(value) }
            } footer: {
                Text("Master switch. When off, narration is never interrupted by speech.")
            }

            Section {
                knob(
                    "Speech Confidence",
                    value: $confidence,
                    range: Double(BargeInTuning.confidenceRange.lowerBound)...Double(BargeInTuning.confidenceRange.upperBound),
                    step: 0.05,
                    format: "%.2f"
                ) { BargeInTuning.setConfidenceThreshold(Float(confidence)) }
            } header: {
                Text("Sensitivity")
            } footer: {
                Text("How sure the detector must be it is hearing real speech. Higher ignores quieter or less speech-like background noise.")
            }

            Section {
                knob(
                    "Hold-to-Interrupt",
                    value: $sustainedMs,
                    range: BargeInTuning.sustainedMsRange,
                    step: 50,
                    format: "%.0f ms"
                ) { BargeInTuning.setSustainedSpeechMs(Int(sustainedMs)) }
            } footer: {
                Text("How long you must keep talking before narration is interrupted. Higher makes it harder to interrupt and immune to brief noise or echo. This is the main anti-false-trigger knob.")
            }

            Section {
                knob(
                    "Auto-Resume After",
                    value: $resumeSec,
                    range: BargeInTuning.resumeSecRange,
                    step: 0.5,
                    format: "%.1f s"
                ) { BargeInTuning.setResumeAfterNoEngagementSec(resumeSec) }
            } header: {
                Text("Recovery")
            } footer: {
                Text("If a barge-in pauses narration but you do not actually say anything, narration resumes after this long, so it never gets stuck.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    BargeInTuning.resetToDefaults()
                    enabled = BargeInTuning.enabled
                    confidence = Double(BargeInTuning.confidenceThreshold)
                    sustainedMs = Double(BargeInTuning.sustainedSpeechMs)
                    resumeSec = BargeInTuning.resumeAfterNoEngagementSec
                }
            } footer: {
                Text("Changes apply to the next voice session. Tune in a real environment, then we make the winning values the permanent defaults.")
            }
        }
        .navigationTitle("Barge-In Tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func knob(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        onCommit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            .accessibilityValue(String(format: format, value.wrappedValue))
        }
    }
}

#Preview {
    NavigationStack { BargeInTuningView() }
}
