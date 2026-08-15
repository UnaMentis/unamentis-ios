// UnaMentis - Aural Skills Views
// The phone surface: a dashboard of skill-area cards with mastery rings, and
// a minimal drill session view. The session view is a thin shell over the
// SAME headless drill loop the conformance suite drives (AuralDrill.run);
// every control it shows is also voice-drivable, per HANDS_FREE_FIRST.

import SwiftUI

// MARK: - Dashboard

/// The module root: one card per skill area with a mastery ring and a
/// start-drill affordance, plus the exam-alignment note.
struct AuralSkillsDashboardView: View {
    @State private var mastery: [AuralSkillArea: Double] = [:]
    @State private var selectedArea: AuralSkillArea?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Name what you hear. Prompts play as sound; answer by voice.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(AuralSkillArea.allCases) { area in
                    AuralSkillAreaCard(
                        area: area,
                        mastery: mastery[area] ?? 0
                    ) {
                        selectedArea = area
                    }
                }

                Text("Aligned with ABRSM-style aural tests (grades 1 to 5 coverage in the starter pack), while training listening as a universal skill.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding()
        }
        .navigationTitle("Aural Skills")
        .task { await loadMastery() }
        .navigationDestination(item: $selectedArea) { area in
            AuralDrillSessionView(area: area)
        }
    }

    private func loadMastery() async {
        let host = await AuralSkillsRuntime.currentHost()
        var loaded: [AuralSkillArea: Double] = [:]
        for area in AuralSkillArea.allCases {
            let proficiency = await host.progress.proficiency(for: area.domain)
            loaded[area] = proficiency.observationCount > 0 ? proficiency.mastery : 0
        }
        mastery = loaded
    }
}

/// One skill-area card: mastery ring, area name, start button.
struct AuralSkillAreaCard: View {
    let area: AuralSkillArea
    let mastery: Double
    let onStart: () -> Void

    /// The ring grows with Dynamic Type so its percentage label still fits at
    /// accessibility text sizes.
    @ScaledMetric(relativeTo: .caption2) private var ringSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 16) {
            MasteryRing(fraction: mastery / 100)
                .frame(width: ringSize, height: ringSize)
                .accessibilityLabel("\(area.displayName) mastery \(Int(mastery)) percent")

            VStack(alignment: .leading, spacing: 4) {
                Text(area.displayName)
                    .font(.headline)
                Text("\(Int(mastery))% mastery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onStart) {
                Label("Drill", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .accessibilityLabel("Start \(area.displayName) drill")
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A simple circular mastery indicator.
struct MasteryRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.indigo.opacity(0.2), lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.indigo, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// The compact card for the Learning tab.
struct AuralSkillsDashboardCard: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Aural Skills")
                    .font(.headline)
                Text("Ear training by voice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "music.quarternote.3")
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Drill Session

/// Minimal drill session surface: prompt state, replay, live transcript, and
/// feedback. Everything shown here is also drivable purely by voice.
struct AuralDrillSessionView: View {
    let area: AuralSkillArea
    @StateObject private var model = AuralDrillViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Reduce Motion turns the running-drill waveform into a static glyph.
    /// The drill is voice-first, so the animation is decoration; the spoken
    /// prompt and the on-screen status carry the same information.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The waveform glyph scales with Dynamic Type instead of pinning to 44pt.
    @ScaledMetric(relativeTo: .largeTitle) private var waveformSize: CGFloat = 44

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(model.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.status)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "waveform")
                .font(.system(size: waveformSize))
                .foregroundStyle(.indigo)
                .symbolEffect(.variableColor, isActive: model.isRunning && !reduceMotion)
                .accessibilityHidden(true)

            if !model.transcript.isEmpty {
                Text("Heard: \u{201C}\(model.transcript)\u{201D}")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !model.feedback.isEmpty {
                Text(model.feedback)
                    .font(.headline)
                    .foregroundStyle(model.feedbackWasCorrect ? .green : .orange)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    model.requestReplay()
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning)
                .accessibilityLabel("Replay the prompt")

                Button(role: .destructive) {
                    model.stop()
                    dismiss()
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("End the drill")
            }

            Text("Say \u{201C}repeat\u{201D} to hear it again, \u{201C}skip\u{201D} to move on, or \u{201C}exit\u{201D} to finish.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("\(area.displayName) Drill")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start(area: area) }
        .onDisappear { model.stop() }
    }
}

/// Drives the headless drill loop from the UI, mirroring its progress.
@MainActor
final class AuralDrillViewModel: ObservableObject {
    @Published var status = "Starting..."
    @Published var transcript = ""
    @Published var feedback = ""
    @Published var feedbackWasCorrect = false
    @Published var progressText = ""
    @Published var isRunning = false

    private var runTask: Task<Void, Never>?
    private let control = AuralDrillControl()

    func start(area: AuralSkillArea) async {
        guard runTask == nil else { return }
        isRunning = true
        let control = self.control

        runTask = Task { [weak self] in
            let host = await AuralSkillsRuntime.currentHost()
            var session: (any VoiceSession)?
            do {
                // The HOST arbitrates the pipeline; the view acquires and is
                // therefore responsible for releasing on every exit path.
                let acquired = try await host.voice.acquire(config: VoicePipelineConfig(
                    endpointing: EndpointingPolicy(silenceThreshold: 1.2, maxUtteranceDuration: 10),
                    bargeIn: .off,
                    answerTimeout: .seconds(12)
                ))
                session = acquired

                let observer = AuralDrillObserver(
                    onStatus: { text in
                        Task { @MainActor [weak self] in self?.status = text }
                    },
                    onTranscript: { text in
                        Task { @MainActor [weak self] in self?.transcript = text }
                    },
                    onFeedback: { text, correct in
                        Task { @MainActor [weak self] in
                            self?.feedback = text
                            self?.feedbackWasCorrect = correct
                        }
                    },
                    onProgress: { index, total, correct in
                        Task { @MainActor [weak self] in
                            self?.progressText = "Item \(index) of \(total) | \(correct) correct"
                        }
                    }
                )

                _ = try await AuralDrill.run(
                    moduleId: "aural-skills",
                    host: host,
                    session: acquired,
                    area: area,
                    rounds: AuralDrill.defaultRoundLength,
                    claimedCommands: [.quit, .skip, .repeatLast],
                    control: control,
                    observer: observer
                )
            } catch is CancellationError {
                // Stopped by the user; the summary already spoke if reached.
            } catch {
                Task { @MainActor [weak self] in
                    self?.status = "Drill unavailable: \(error.localizedDescription)"
                }
            }
            if let session {
                await session.release()
            }
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }
        await runTask?.value
        runTask = nil
    }

    /// Replay the current prompt (same path as the voice command).
    func requestReplay() {
        Task { [control] in
            await control.requestRepeat()
        }
    }

    /// End the drill: sets the quit flag and cancels a listen in progress.
    func stop() {
        Task { [control] in
            await control.honor(.quit)
        }
        runTask?.cancel()
    }
}
