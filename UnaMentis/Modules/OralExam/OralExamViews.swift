// UnaMentis - Oral Exam Studio Views
// The phone surface: dashboard (exam picker, session mode cards, rubric trend
// placeholder) and the session view (stage timer with milestones, optional
// live transcript, feedback with per-dimension scores, improvement actions,
// and a replayable spoken summary).
//
// Feedback contract (ORAL_EXAM_STUDIO_MODULE_SPEC.md section 5): scores are
// practice signals; the UI must never present them as predictions of real
// exam grades, so the feedback screen carries that disclaimer verbatim.

import SwiftUI

// MARK: - Dashboard

struct OralExamDashboardView: View {
    @State private var descriptors: [OralExamFormatDescriptor] = []
    @State private var topics: [OralSyllabusItem] = []
    @State private var loadError: String?
    @State private var selectedFormatId: String = "practice-viva"
    @State private var selectedTopicId: String?
    @State private var recentAttempts: [AttemptRecord] = []

    private var selectedDescriptor: OralExamFormatDescriptor? {
        descriptors.first { $0.formatId == selectedFormatId }
    }

    private var sessionReadyTopics: [OralSyllabusItem] {
        OralSyllabusPack.sessionReadyItems(from: topics)
    }

    private var selectedTopic: OralSyllabusItem? {
        sessionReadyTopics.first { $0.id == selectedTopicId } ?? sessionReadyTopics.first
    }

    var body: some View {
        List {
            examSection
            topicSection
            modeSection
            trendSection
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Oral Exam Studio")
        .task { await load() }
    }

    // MARK: Sections

    private var examSection: some View {
        Section("Exam Format") {
            ForEach(descriptors, id: \.formatId) { descriptor in
                Button {
                    selectedFormatId = descriptor.formatId
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.displayName(for: descriptor.formatId))
                                .font(.headline)
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(Self.stageSummary(descriptor))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if descriptor.language.lowercased().hasPrefix("fr") {
                                    // The Grand Oral descriptor is French; the
                                    // pipeline runs en-US only today (RFC 0002
                                    // item 6), so it runs as English practice.
                                    Text("English practice mode")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.indigo.opacity(0.15))
                                        .foregroundStyle(.indigo)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        Spacer()
                        if descriptor.formatId == selectedFormatId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.indigo)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Select \(Self.displayName(for: descriptor.formatId))")
                .accessibilityAddTraits(descriptor.formatId == selectedFormatId ? .isSelected : [])
            }
        }
    }

    private var topicSection: some View {
        Section("Topic") {
            if sessionReadyTopics.isEmpty {
                Text("No topics available")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Topic", selection: Binding(
                    get: { selectedTopic?.id ?? "" },
                    set: { selectedTopicId = $0 }
                )) {
                    ForEach(sessionReadyTopics) { topic in
                        Text(topic.title).tag(topic.id)
                    }
                }
                .accessibilityLabel("Choose a topic")
            }
            let frenchCount = topics.count - sessionReadyTopics.count
            if frenchCount > 0 {
                Text("\(frenchCount) French topics ship in this pack and unlock with multilingual speech support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeSection: some View {
        Section("Session Mode") {
            if let descriptor = selectedDescriptor, let topic = selectedTopic {
                modeCard(
                    title: "Question Volleys",
                    subtitle: "Rapid follow-up questions on your topic",
                    icon: "bubble.left.and.bubble.right",
                    config: OralExamSessionConfig(
                        descriptor: descriptor,
                        topic: topic.engineTopic,
                        mode: .questionVolley(rootQuestions: 3)
                    )
                )
                modeCard(
                    title: "Stage Practice: Presentation",
                    subtitle: "Just the presentation, with coaching after",
                    icon: "person.wave.2",
                    config: OralExamSessionConfig(
                        descriptor: descriptor,
                        topic: topic.engineTopic,
                        mode: .stagePractice(.presentation)
                    )
                )
                modeCard(
                    title: "Stage Practice: Questioning",
                    subtitle: "Just the jury questions, with coaching after",
                    icon: "questionmark.bubble",
                    config: OralExamSessionConfig(
                        descriptor: descriptor,
                        topic: topic.engineTopic,
                        mode: .stagePractice(.questioning)
                    )
                )
                modeCard(
                    title: "Full Simulation",
                    subtitle: "The complete exam flow with real timing",
                    icon: "timer",
                    config: OralExamSessionConfig(
                        descriptor: descriptor,
                        topic: topic.engineTopic,
                        mode: .fullSimulation
                    )
                )
            } else {
                Text("Select an exam format and topic to start.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `title` and `subtitle` are LocalizedStringKey so the literals at the
    /// call sites stay extractable; VoiceOver reads the combined children
    /// rather than a hand-assembled label, which would need raw strings.
    private func modeCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        config: OralExamSessionConfig
    ) -> some View {
        NavigationLink {
            OralExamSessionView(viewModel: OralExamSessionViewModel(config: config))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
    }

    /// Rubric trend placeholder: real trendlines arrive with the review mode
    /// (module spec Phase 2); until then this shows recent practice volume
    /// from stored attempts.
    private var trendSection: some View {
        Section("Progress") {
            if recentAttempts.isEmpty {
                Text("No attempts yet. Rubric trends will appear here after your first session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(recentAttempts.count) answers recorded")
                            .font(.headline)
                        Text("Rubric trendlines arrive with review mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Data

    /// What one dashboard load produced, off the main actor.
    private struct LoadedContent: Sendable {
        var descriptors: [OralExamFormatDescriptor] = []
        var topics: [OralSyllabusItem] = []
        var error: String?
    }

    private func load() async {
        let content = await Self.loadContent()
        descriptors = content.descriptors
        topics = content.topics
        loadError = content.error

        let host = await OralExamModuleRuntime.currentHost()
        recentAttempts = await host.progress.exportAll(for: "oral-exam").attempts
    }

    /// Read the bundled descriptors and the starter syllabus pack.
    ///
    /// `nonisolated` on purpose: this is file IO, JSON decoding, and the
    /// pack's SHA-256 verification, and on the MainActor it stalls the first
    /// frame of the dashboard. A nonisolated async function does not inherit
    /// the caller's actor, so this runs on the cooperative pool and only the
    /// assignment of the results hops back.
    private nonisolated static func loadContent() async -> LoadedContent {
        var content = LoadedContent()

        for name in ["practice-viva", "fr-grand-oral", "fr-grand-oral-practice"] {
            if let descriptor = try? OralExamFormatDescriptor.load(named: name) {
                content.descriptors.append(descriptor)
            }
        }
        if content.descriptors.isEmpty {
            content.error = "No exam formats could be loaded."
        }

        do {
            content.topics = try OralSyllabusPack.loadBundled().items
        } catch {
            content.error = error.localizedDescription
        }
        return content
    }

    static func displayName(for formatId: String) -> String {
        switch formatId {
        case "fr-grand-oral": return "Bac Grand Oral"
        case "fr-grand-oral-practice": return "Grand Oral (Practice Timing)"
        case "practice-viva": return "Practice Viva"
        default: return formatId
        }
    }

    static func stageSummary(_ descriptor: OralExamFormatDescriptor) -> String {
        descriptor.stages
            .map { "\(Int($0.seconds / 60))m \($0.kind.rawValue)" }
            .joined(separator: " + ")
    }
}

// MARK: - Dashboard Summary (Learning tab card)

struct OralExamDashboardSummary: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Oral Exam Studio")
                    .font(.headline)
                Text("Rehearse with an AI examiner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Session View

struct OralExamSessionView: View {
    @StateObject var viewModel: OralExamSessionViewModel
    @Environment(\.dismiss) private var dismiss

    /// Reduce Motion stops the repeating listening indicator. The "Listening"
    /// label and the spoken examiner turn already carry the state, so the
    /// animation is decoration.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed-size glyphs and the timer readout scale with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var startGlyphSize: CGFloat = 56
    @ScaledMetric(relativeTo: .largeTitle) private var completedGlyphSize: CGFloat = 48
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var timerDiameter: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .notStarted:
                startScreen
            case .runningStage(let kind, _):
                stageScreen(kind: kind)
            case .assemblingFeedback:
                ProgressView("Scoring your attempt...")
                    .frame(maxHeight: .infinity)
            case .feedback:
                if let feedback = viewModel.feedback {
                    OralExamFeedbackView(
                        feedback: feedback,
                        onReplay: { Task { await viewModel.replaySummary() } },
                        onDone: {
                            viewModel.releaseVoice()
                            dismiss()
                        }
                    )
                }
            case .completed:
                completedScreen
            }
        }
        .navigationTitle(OralExamDashboardView.displayName(for: viewModel.config.descriptor.formatId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .runningStage = viewModel.state {
                    Button("End") {
                        Task { await viewModel.endSession() }
                    }
                    .accessibilityLabel("End session")
                }
            }
        }
        .onDisappear {
            Task {
                await viewModel.endSession()
                viewModel.releaseVoice()
            }
        }
    }

    // MARK: Start

    private var startScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: startGlyphSize))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text(viewModel.config.topic.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Your examiner is an AI. It listens, asks follow-up questions grounded in what you say, and coaches you afterwards.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
            Button {
                Task { await viewModel.startSession() }
            } label: {
                Label(
                    viewModel.isPreparingServices ? "Preparing..." : "Start",
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(viewModel.isPreparingServices)
            .padding()
            .accessibilityLabel("Start oral exam session")
        }
        .padding()
    }

    // MARK: Stage

    private func stageScreen(kind: OralExamFormatDescriptor.Stage.Kind) -> some View {
        VStack(spacing: 20) {
            stageTimer
            Text(stageTitle(kind))
                .font(.title3.weight(.semibold))

            if viewModel.usingOfflineExaminer {
                Text("Offline examiner (no language model reachable)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !viewModel.lastPrompt.isEmpty {
                Text(viewModel.lastPrompt)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .accessibilityLabel("Examiner said: \(viewModel.lastPrompt)")
            }

            if viewModel.isListening {
                Label("Listening", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.indigo)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: reduceMotion ? .nonRepeating : .repeating,
                        isActive: !reduceMotion
                    )
            }

            Toggle("Show live transcript", isOn: $viewModel.showLiveTranscript)
                .padding(.horizontal)
                .accessibilityLabel("Show live transcript")

            if viewModel.showLiveTranscript {
                ScrollView {
                    Text(transcriptText)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(.horizontal)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()

            HStack(spacing: 12) {
                if kind == .questioning {
                    Button {
                        Task { await viewModel.skipQuestion() }
                    } label: {
                        Text("Skip Question")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Skip this question")
                }
                Button {
                    Task { await viewModel.endStage() }
                } label: {
                    Text(kind == .preparation ? "Ready" : "Done")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .accessibilityLabel(kind == .preparation ? "Ready to begin" : "Finish this stage")
            }
            .padding()
        }
        .padding(.top)
    }

    private var transcriptText: String {
        var parts = viewModel.capturedSegments
        if !viewModel.liveTranscript.isEmpty {
            parts.append(viewModel.liveTranscript)
        }
        return parts.joined(separator: " ")
    }

    private var stageTimer: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 8)
                .frame(width: timerDiameter, height: timerDiameter)
            Circle()
                .trim(from: 0, to: max(0, min(1, viewModel.timerProgress)))
                .stroke(
                    viewModel.timerRemaining < 15 ? Color.red : Color.indigo,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: timerDiameter, height: timerDiameter)
                .rotationEffect(.degrees(-90))
            VStack {
                Text(Self.format(viewModel.timerRemaining))
                    .font(.system(size: timerFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !viewModel.milestoneAnnouncement.isEmpty {
                    Text(viewModel.milestoneAnnouncement)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time remaining: \(Self.format(viewModel.timerRemaining))")
    }

    private func stageTitle(_ kind: OralExamFormatDescriptor.Stage.Kind) -> LocalizedStringKey {
        switch kind {
        case .preparation: return "Preparation"
        case .presentation: return "Presentation"
        case .questioning: return "Questioning"
        }
    }

    private var completedScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "flag.checkered")
                .font(.system(size: completedGlyphSize))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text("Session Complete")
                .font(.title2.bold())
            if let summary = viewModel.summary {
                Text("\(summary.responsesCaptured) responses across \(summary.stagesCompleted) stage\(summary.stagesCompleted == 1 ? "" : "s").")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.releaseVoice()
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .padding()
            .accessibilityLabel("Close session")
        }
        .padding()
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Feedback View

struct OralExamFeedbackView: View {
    let feedback: OralExamFeedback
    let onReplay: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Feedback")
                    .font(.title.bold())
                    .padding(.top)

                ForEach(feedback.scores, id: \.dimension) { score in
                    dimensionRow(score)
                }

                deliverySection

                Button(action: onReplay) {
                    Label("Replay Spoken Summary", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Replay the spoken feedback summary")

                Text(feedback.spokenSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Regulatory and honesty requirement (module spec section 5).
                Text("These scores are practice signals to guide your rehearsal. They are not a prediction of your real exam grade.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)

                Button(action: onDone) {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .accessibilityLabel("Close feedback")
            }
            .padding()
        }
    }

    private func dimensionRow(_ score: RubricScore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(score.dimension.capitalized)
                    .font(.headline)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: index < score.score ? "circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(score.dimension): \(score.score) out of 5")
            }
            Label(score.improvementAction, systemImage: "arrow.up.right")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delivery")
                .font(.headline)
            HStack(spacing: 16) {
                metric(
                    value: feedback.deliveryMetrics.wordsPerMinute > 0
                        ? "\(Int(feedback.deliveryMetrics.wordsPerMinute))"
                        : "-",
                    label: "words/min"
                )
                metric(value: "\(feedback.deliveryMetrics.fillerWordCount)", label: "fillers")
                metric(value: "\(feedback.deliveryMetrics.hesitationCount)", label: "hesitations")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metric(value: String, label: LocalizedStringKey) -> some View {
        VStack {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
